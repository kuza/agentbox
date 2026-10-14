# Graylog: log search through Graylog's built-in MCP endpoint (Graylog 7.0+).
# An nginx sidecar adds the Authorization header (nginx.conf.template), so
# the API token never reaches the agent.
MCP_DESCRIPTION="Search and analyse logs in Graylog (read-only)"
MCP_URL="http://ab-mcp-graylog:8080/mcp"
MCP_CONFIG=(GRAYLOG_URL)
MCP_REQUIRED_CONFIG=(GRAYLOG_URL)
MCP_SECRETS=(graylog_basic)
MCP_IMAGES=("$IMG_NGINX")

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
    -v "$MCP_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
