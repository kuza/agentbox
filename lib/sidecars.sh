# Sidecars. Started once and reused across sessions, so several sessions can
# run in parallel. Set AB_RESTART=1 to recreate them after changing config.

SIDECARS_WANTED=()

start_sidecar() {  # <name> <podman run arguments...>
  local name="$1"; shift
  SIDECARS_WANTED+=("$name")
  if [[ "${AB_RESTART:-}" != 1 ]] \
     && [[ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    return 0
  fi
  # -v: with the container's anonymous volumes (squid declares some), which
  # would otherwise stay behind on every recreation.
  podman rm -f -v "$name" >/dev/null 2>&1 || true
  podman run -d --replace --name "$name" "$@" >/dev/null
}

# Removes agentbox sidecars this start did not ask for: those of MCP modules
# no longer in AB_MCP, ab-llm-openai once its key is gone. Sidecars are named
# ab-egress, ab-mcp-* or ab-llm-*. A second agentbox setup with another
# AB_CONFIG on the same host would remove the other's sidecars.
sidecars_cleanup() {
  local name wanted=" ${SIDECARS_WANTED[*]} "
  for name in $(podman ps -a --format '{{.Names}}' | awk '{ print $1 }'); do
    [[ "$name" == ab-egress || "$name" == ab-mcp-* || "$name" == ab-llm-* ]] || continue
    [[ "$wanted" == *" $name "* ]] && continue
    podman rm -f -v "$name" >/dev/null && echo "agentbox: removed $name, no longer enabled" >&2
  done
}

# Config files reach sidecars as copies in the cache, never from the repo.
# A sidecar mounts its files with ":Z", a label private to that container; on
# the repo's own file that label would lock out agent sessions and git in
# them (README, Troubleshooting). Each container gets its own copy, written
# anew and renamed, so a running sidecar keeps the version it mounted.
sidecar_copy() {  # <container> <file>: prints the path of a fresh copy
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/$1" dst tmp
  dst="$dir/$(basename "$2")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dst.XXXXXX")"
  cp -- "$2" "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$dst"
  printf '%s\n' "$dst"
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

# OpenAI for pi (optional): enabled only if the openai_api_key secret exists.
#   ab-llm-openai  nginx on both networks: checks the caller token, replaces it
#                  with the real API key and forwards to api.openai.com with
#                  certificate verification (pi/llm-openai.conf.template).
# pi points its built-in openai provider at this sidecar (pi/models.json), so
# the API key never enters the agent container.
openai_start() {
  podman secret inspect openai_api_key >/dev/null 2>&1 || return 0
  ensure_caller_secret llm_openai_caller
  start_sidecar ab-llm-openai \
    --network ab-internal --network ab-egress \
    --secret openai_api_key,type=env,target=OPENAI_API_KEY \
    --secret llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN \
    -v "$(sidecar_copy ab-llm-openai "$SCRIPT_DIR/pi/llm-openai.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
