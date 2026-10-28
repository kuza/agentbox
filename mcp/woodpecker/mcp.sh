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
MCP_DESCRIPTION="Woodpecker CI pipelines, step logs and configs (read-only)"
MCP_URL="http://ab-mcp-woodpecker:8080/mcp"
MCP_CONFIG=(WOODPECKER_URL WOODPECKER_CA)
MCP_REQUIRED_CONFIG=(WOODPECKER_URL)
MCP_SECRETS=(woodpecker_token)
MCP_SECRET_HELP=("woodpecker_token: a personal access token of a Woodpecker user that can only read the repos the agent needs (README, Woodpecker (MCP))")
MCP_OWN_SECRETS=(woodpecker_bridge_key)
MCP_CALLER_SECRET=woodpecker_mcp_caller
WOODPECKER_MCP_IMAGE="ghcr.io/rtuszik/woodpecker-mcp:0.5.3"
MCP_IMAGES=("$WOODPECKER_MCP_IMAGE" "$IMG_NGINX")

#   WOODPECKER_URL  base URL of the Woodpecker server, without /api
#   WOODPECKER_CA   optional: a CA certificate file on the host for an https
#                   Woodpecker signed by your own CA (default: the public
#                   CAs nginx's image trusts)
mcp_start() {
  local url="$WOODPECKER_URL" ca=/etc/ssl/certs/ca-certificates.crt ca_mount=() srv_id f
  url="${url%"${url##*[!/]}"}"; url="${url%/api}"; url="${url%"${url##*[!/]}"}"
  # It goes into nginx's config: plain URL characters only, no ; { } $ # or
  # quotes, which would change the config, and no user:password@, which
  # proxy_pass cannot take.
  if [[ ! "$url" =~ ^https?://[A-Za-z0-9._~:/%+=,!*-]+$ ]]; then
    echo "error: WOODPECKER_URL must be an http:// or https:// URL of plain characters, got '$WOODPECKER_URL'" >&2
    exit 2
  fi
  if [[ "$url" == http://* ]]; then
    echo "agentbox: warning: WOODPECKER_URL is http://: the Woodpecker token, which can do all its user can," \
         "goes over the network unencrypted" >&2
  fi
  if [[ -n "${WOODPECKER_CA:-}" ]]; then
    ca=/etc/nginx/woodpecker-ca.pem
    f="$(sidecar_copy ab-mcp-woodpecker "$WOODPECKER_CA")" || exit 1
    ca_mount=(-v "$f:$ca:ro,Z")
  fi
  # A random key between nginx and the server, made once.
  ensure_caller_secret woodpecker_bridge_key
  # The server's isolation is this network's: one of that name made
  # otherwise is not used.
  if ! podman network exists ab-mcp-woodpecker; then
    podman network create --internal ab-mcp-woodpecker >/dev/null
  elif [[ "$(podman network inspect ab-mcp-woodpecker --format '{{.Internal}}' 2>/dev/null)" != true ]]; then
    echo "error: podman network ab-mcp-woodpecker is not --internal: the Woodpecker MCP server would have a way out." >&2
    echo "  Remove it, the next start makes it anew: podman rm -f ab-mcp-woodpecker ab-mcp-woodpecker-srv; podman network rm ab-mcp-woodpecker" >&2
    exit 1
  fi

  start_sidecar ab-mcp-woodpecker-srv \
    --network ab-mcp-woodpecker --dns 127.0.0.1 \
    -e WOODPECKER_SERVER=http://ab-mcp-woodpecker:8081 \
    -e WOODPECKER_MCP_READ_ONLY=true \
    -e PORT=8000 \
    "$WOODPECKER_MCP_IMAGE"
  # nginx resolves the server's name once, when it starts: recreated with
  # the server (its ID as a label), as in mcp/github.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-woodpecker-srv 2>/dev/null || true)"
  start_sidecar ab-mcp-woodpecker \
    --network ab-internal --network ab-egress --network ab-mcp-woodpecker \
    --label "agentbox.upstream=$srv_id" \
    -e WOODPECKER_URL="$url" \
    -e WOODPECKER_CA_FILE="$ca" \
    --secret woodpecker_token,type=env,target=WP_TOKEN \
    --secret woodpecker_bridge_key,type=env,target=WP_BRIDGE_KEY \
    --secret woodpecker_mcp_caller,type=env,target=WP_CALLER_TOKEN \
    ${ca_mount[@]+"${ca_mount[@]}"} \
    -v "$(sidecar_copy ab-mcp-woodpecker "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
