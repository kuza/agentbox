# Woodpecker CI: pipelines, step logs and pipeline configs, read-only,
# through rtuszik/woodpecker-mcp (README, Woodpecker (MCP)). Woodpecker's
# personal access tokens have no scopes: one can do all its user can,
# starting pipelines with the CI's secrets included. So the token never
# reaches the MCP server, and writing is refused by nginx, whatever the
# server's code does:
#   ab-mcp-woodpecker-srv  woodpecker-mcp in read-only mode, only on the
#                          --internal network ab-mcp-woodpecker, with no DNS
#                          for outside names (--dns 127.0.0.1): it sees
#                          nginx and nothing else, not squid on ab-internal,
#                          and the agent does not see it. Its Woodpecker
#                          "server" is nginx's port 8081, and the token it
#                          forwards there is the bridge key, not Woodpecker's
#   ab-mcp-woodpecker      nginx on ab-internal, ab-egress and
#                          ab-mcp-woodpecker (nginx.conf.template):
#                          8080  the agent's: checks the caller token,
#                                sends the bridge key on to the server
#                          8081  the server's: checks the bridge key, lets
#                                GET and HEAD through only, puts in the
#                                Woodpecker token, verifies Woodpecker's
#                                certificate
# module.toml holds the data of the module. The url check of WOODPECKER_URL
# keeps the characters that would change the config of nginx (; { } $ # and
# quotes) and a user:password@ out of it.
mcp_start() {
  # The URL with no /api and no / at the end. Only the path loses /api, so a
  # host named api stays.
  local url="${MCP_FIELD[WOODPECKER_URL.scheme]}://${MCP_FIELD[WOODPECKER_URL.hostport]}" path
  local ca=/etc/ssl/certs/ca-certificates.crt ca_mount=() srv_id f
  path="${MCP_FIELD[WOODPECKER_URL.base]#"$url"}"
  path="${path%/api}"
  url+="${path%"${path##*[!/]}"}"
  if [[ "$url" == http://* ]]; then
    ab_warn "WOODPECKER_URL is http://: the Woodpecker token, which can do all its user can," \
         "goes over the network unencrypted"
  fi
  if [[ -n "${WOODPECKER_CA:-}" ]]; then
    ca=/etc/nginx/woodpecker-ca.pem
    f="$(sidecar_copy ab-mcp-woodpecker "$WOODPECKER_CA")" || exit 1
    ca_mount=(-v "$f:$ca:ro,Z")
  fi
  # A random key between nginx and the server, made once.
  ensure_caller_secret "${MCP_SECRET[bridge_key]}"
  # The server's isolation is this network's: one of that name made
  # otherwise is not used.
  if ! podman network exists ab-mcp-woodpecker; then
    podman network create --internal ab-mcp-woodpecker >/dev/null
  elif [[ "$(podman network inspect ab-mcp-woodpecker --format '{{.Internal}}' 2>/dev/null)" != true ]]; then
    ab_error "podman network ab-mcp-woodpecker is not --internal: the Woodpecker MCP server would have a way out."
    echo "  Remove it, the next start makes it anew: podman network rm ab-mcp-woodpecker" >&2
    # Not left running on it for the sessions open now (lib/mcp.sh).
    exit "$MCP_TAKE_AWAY"
  fi

  start_sidecar ab-mcp-woodpecker-srv \
    --network ab-mcp-woodpecker --dns 127.0.0.1 \
    -e WOODPECKER_SERVER=http://ab-mcp-woodpecker:8081 \
    -e WOODPECKER_MCP_READ_ONLY=true \
    -e PORT=8000 \
    "${MCP_IMAGE[server]}"
  # nginx resolves the server's name once, when it starts: recreated with
  # the server (its ID as a label), as in mcp/github.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-woodpecker-srv 2>/dev/null || true)"
  start_sidecar ab-mcp-woodpecker \
    --network ab-internal --network ab-egress --network ab-mcp-woodpecker \
    --label "agentbox.upstream=$srv_id" \
    -e WOODPECKER_URL="$url" \
    -e WOODPECKER_CA_FILE="$ca" \
    --secret "${MCP_SECRET[token]},type=env,target=WP_TOKEN" \
    --secret "${MCP_SECRET[bridge_key]},type=env,target=WP_BRIDGE_KEY" \
    --secret "${MCP_SECRET[mcp_caller]},type=env,target=WP_CALLER_TOKEN" \
    ${ca_mount[@]+"${ca_mount[@]}"} \
    -v "$(sidecar_copy ab-mcp-woodpecker "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
