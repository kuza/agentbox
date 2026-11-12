# The code of the grafana module: module.toml holds its data.
#   GRAFANA_URL                base URL, without /api
#   MCP_GRAFANA_SERVER_TOKEN   callers must send "Authorization: Bearer <token>"
#   GRAFANA_USAGE_STATS        no anonymous usage reporting to Grafana Labs
#   --allowed-hosts            DNS-rebinding protection: only accept the Host
#                              header the agent sends
#   --disable-write            no write operations to Grafana, on top of the
#                              Viewer role of the service account
mcp_start() {
  start_sidecar ab-mcp-grafana \
    --network ab-internal --network ab-egress \
    -e GRAFANA_URL="${GRAFANA_URL%/}" \
    -e GRAFANA_USAGE_STATS=disabled \
    --secret "${MCP_SECRET[sa]},type=env,target=GRAFANA_SERVICE_ACCOUNT_TOKEN" \
    --secret "${MCP_SECRET[mcp_caller]},type=env,target=MCP_GRAFANA_SERVER_TOKEN" \
    "${MCP_IMAGE[server]}" \
    -t streamable-http --address 0.0.0.0:8000 \
    --allowed-hosts ab-mcp-grafana:8000,ab-mcp-grafana \
    --disable-write
}
