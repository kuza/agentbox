# Graylog: log search through Graylog's built-in MCP endpoint (Graylog 7.0+).
# An nginx sidecar checks the caller token and replaces it with Graylog's
# Authorization header (nginx.conf.template), so the API token never reaches
# the agent.
MCP_DESCRIPTION="Search and analyse logs in Graylog (read-only)"
MCP_URL="http://ab-mcp-graylog:8080/mcp"
MCP_CONFIG=(GRAYLOG_URL)
MCP_REQUIRED_CONFIG=(GRAYLOG_URL)
MCP_SECRETS=(graylog_basic)
MCP_SECRET_HELP=("graylog_basic: a Graylog API token of a read-only user (README, step 2)")
MCP_CALLER_SECRET=graylog_mcp_caller
MCP_IMAGES=("$IMG_NGINX")

# The secret holds Graylog's basic auth for a token, base64("<token>:token");
# agentbox setup asks for the token and stores this.
mcp_secret_value() {  # <secret> <typed>
  printf '%s:token' "$2" | base64 -w0
}

#   GRAYLOG_URL     base URL; nginx appends /api/mcp. A trailing slash, /api or
#                   /api/mcp in the setting is stripped.
#   GRAYLOG_BASIC   base64("<api-token>:token"), from the podman secret
mcp_start() {
  local url="${GRAYLOG_URL%/}"
  url="${url%/api/mcp}"
  url="${url%/api}"
  start_sidecar ab-mcp-graylog \
    --network ab-internal --network ab-egress \
    -e GRAYLOG_URL="$url" \
    --secret graylog_basic,type=env,target=GRAYLOG_BASIC \
    --secret graylog_mcp_caller,type=env,target=GRAYLOG_CALLER_TOKEN \
    -v "$(sidecar_copy ab-mcp-graylog "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
