# Grafana: dashboards, alerts, Prometheus and Loki queries through the
# official grafana/mcp-grafana server. The service account token exists only
# in the sidecar; agents authenticate to the sidecar with the caller token.
MCP_DESCRIPTION="Grafana dashboards, alerts and Prometheus/Loki queries (read-only)"
MCP_URL="http://ab-mcp-grafana:8000/mcp"
MCP_CONFIG=(GRAFANA_URL)
MCP_REQUIRED_CONFIG=(GRAFANA_URL)
MCP_SECRETS=(grafana_sa)
MCP_CALLER_SECRET=grafana_mcp_caller
MCP_IMAGES=(docker.io/grafana/mcp-grafana:latest)

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
    --secret grafana_sa,type=env,target=GRAFANA_SERVICE_ACCOUNT_TOKEN \
    --secret grafana_mcp_caller,type=env,target=MCP_GRAFANA_SERVER_TOKEN \
    docker.io/grafana/mcp-grafana:latest \
    -t streamable-http --address 0.0.0.0:8000 \
    --allowed-hosts ab-mcp-grafana:8000,ab-mcp-grafana \
    --disable-write
}
