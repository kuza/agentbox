# The code of the graylog module: module.toml holds its data.

# The secret holds Graylog's basic auth for a token, base64("<token>:token");
# agentbox setup asks for the token and stores this.
mcp_secret_value() {  # <secret> <typed>
  printf '%s:token' "$2" | base64 -w0
}

#   GRAYLOG_URL     base URL; nginx appends /api/mcp. mcp_start removes each /
#                   at the end, and then /api or /api/mcp.
#   GRAYLOG_BASIC   base64("<api-token>:token"), from the podman secret
mcp_start() {
  local url="${MCP_FIELD[GRAYLOG_URL.base]}"
  url="${url%/api/mcp}"
  url="${url%/api}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  start_sidecar ab-mcp-graylog \
    --network ab-internal --network ab-egress \
    -e GRAYLOG_URL="$url" \
    --secret "${MCP_SECRET[basic]},type=env,target=GRAYLOG_BASIC" \
    --secret "${MCP_SECRET[mcp_caller]},type=env,target=GRAYLOG_CALLER_TOKEN" \
    -v "$(sidecar_copy ab-mcp-graylog "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
