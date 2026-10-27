# GitHub: pull requests, issues, CI runs and repository contents through the
# official github-mcp-server, with a fine-grained PAT (README, GitHub (MCP)).
#   ab-mcp-github-srv  github-mcp-server, on ab-egress only, so the agent
#                      cannot reach it directly; it has no token of its own
#   ab-mcp-github      nginx on both networks: checks the caller token,
#                      injects the PAT and pins toolsets and lockdown mode
#                      (nginx.conf.template)
MCP_DESCRIPTION="GitHub pull requests, issues, CI runs and repository contents"
MCP_URL="http://ab-mcp-github:8080/mcp"
MCP_CONFIG=(GH_TOOLSETS)
MCP_SECRETS=(github_pat)
MCP_SECRET_HELP=("github_pat: a fine-grained personal access token, read-only (README, GitHub (MCP))")
MCP_CALLER_SECRET=github_mcp_caller
MCP_IMAGES=(ghcr.io/github/github-mcp-server:latest "$IMG_NGINX")

#   GH_TOOLSETS   toolsets nginx pins (default below)
mcp_start() {
  local srv_id
  start_sidecar ab-mcp-github-srv \
    --network ab-egress \
    ghcr.io/github/github-mcp-server:latest http
  # nginx resolves the server's name once, when it starts. The server's
  # container ID as a label makes start_sidecar recreate nginx whenever the
  # server was recreated (check-updates.sh, AB_RESTART), so it never sends
  # requests, with the PAT, to an old address.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-github-srv 2>/dev/null || true)"
  start_sidecar ab-mcp-github \
    --network ab-internal --network ab-egress \
    --label "agentbox.upstream=$srv_id" \
    -e GH_TOOLSETS="${GH_TOOLSETS:-context,repos,issues,pull_requests,actions}" \
    --secret github_pat,type=env,target=GH_PAT \
    --secret github_mcp_caller,type=env,target=GH_CALLER_TOKEN \
    -v "$(sidecar_copy ab-mcp-github "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
