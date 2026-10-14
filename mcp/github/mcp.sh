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
MCP_CALLER_SECRET=github_mcp_caller
MCP_IMAGES=(ghcr.io/github/github-mcp-server:latest "$IMG_NGINX")

#   GH_TOOLSETS   toolsets nginx pins (default below)
mcp_start() {
  start_sidecar ab-mcp-github-srv \
    --network ab-egress \
    ghcr.io/github/github-mcp-server:latest http
  start_sidecar ab-mcp-github \
    --network ab-internal --network ab-egress \
    -e GH_TOOLSETS="${GH_TOOLSETS:-context,repos,issues,pull_requests,actions}" \
    --secret github_pat,type=env,target=GH_PAT \
    --secret github_mcp_caller,type=env,target=GH_CALLER_TOKEN \
    -v "$MCP_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
