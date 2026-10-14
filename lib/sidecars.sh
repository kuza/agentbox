# Sidecars. Started once and reused across sessions, so several sessions can
# run in parallel. Set AB_RESTART=1 to recreate them after changing config.

start_sidecar() {  # <name> <podman run arguments...>
  local name="$1"; shift
  if [[ "${AB_RESTART:-}" != 1 ]] \
     && [[ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    return 0
  fi
  podman run -d --replace --name "$name" "$@" >/dev/null
}

# Caller tokens: a random secret per sidecar that proves the caller may talk
# to it. Not a credential for the service behind it. Generated once.
ensure_caller_secret() {  # <secret name>
  podman secret inspect "$1" >/dev/null 2>&1 && return 0
  head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | podman secret create "$1" - >/dev/null
  echo "agentbox: created secret $1" >&2
}

# Networks
#   ab-internal: --internal, no route to the outside world. The agent lives here.
#   ab-egress:   normal network. Only sidecars are attached to it.
networks_create() {
  podman network exists ab-internal || podman network create --internal ab-internal >/dev/null
  podman network exists ab-egress   || podman network create ab-egress >/dev/null
}

# Egress proxy: the only way out for the agent. squid.conf holds the fixed
# allowlist; the MCP modules' remote hosts come from a generated file
# (MCP_SQUID_CONF, included by squid.conf). When that list changes, squid is
# recreated; open sessions lose egress for a moment.
egress_start() {
  local hash
  hash="$(sha256sum < "$MCP_SQUID_CONF" | cut -c1-16)"
  if [[ "$(podman inspect -f '{{index .Config.Labels "agentbox.mcp-egress"}}' ab-egress 2>/dev/null)" != "$hash" ]]; then
    podman rm -f ab-egress >/dev/null 2>&1 || true
  fi
  start_sidecar ab-egress \
    --network ab-internal --network ab-egress \
    --label "agentbox.mcp-egress=$hash" \
    -v "$SCRIPT_DIR/squid.conf:/etc/squid/squid.conf:ro,Z" \
    -v "$MCP_SQUID_CONF:/etc/squid/agentbox-mcp.conf:ro,Z" \
    "$IMG_SQUID"
}

# OpenAI for pi (optional): enabled only if the openai_api_key secret exists.
#   ab-llm-openai  nginx on both networks: checks the caller token, replaces it
#                  with the real API key and forwards to api.openai.com with
#                  certificate verification (llm-openai.conf.template).
# pi points its built-in openai provider at this sidecar (pi/models.json), so
# the API key never enters the agent container.
openai_start() {
  podman secret inspect openai_api_key >/dev/null 2>&1 || return 0
  ensure_caller_secret llm_openai_caller
  start_sidecar ab-llm-openai \
    --network ab-internal --network ab-egress \
    --secret openai_api_key,type=env,target=OPENAI_API_KEY \
    --secret llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN \
    -v "$SCRIPT_DIR/llm-openai.conf.template:/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
