# GitHub: pull requests, issues, CI runs and repository contents through the
# official github-mcp-server, with a fine-grained PAT (README, GitHub (MCP)).
#   ab-mcp-github-srv  github-mcp-server, on ab-egress only, so the agent
#                      cannot reach it directly; it has no token of its own
#   ab-mcp-github      nginx on both networks: checks the caller token,
#                      injects the PAT and pins toolsets and lockdown mode
#                      (nginx.conf.template)
# A fine-grained PAT has one resource owner (your account or one
# organization). For repositories of more owners, GH_OWNERS lists them: each
# gets its own PAT (secret github_pat_<owner>) and its own MCP server
# github-<owner>, a path of the same nginx (/o/<owner>/mcp) that injects that
# PAT. The server and nginx stay one each.
# module.toml holds the data of the module. mcp_start and
# github_nginx_template take the owners from MCP_ITEMS[GH_OWNERS].

# The toolsets go into a header of nginx: a-z and _ in each one. A value
# of only commas or spaces gives no toolset, and nginx would then send no
# header.
mcp_check() {
  if [[ -z "$GH_TOOLSETS" ]]; then
    echo "GH_TOOLSETS has no toolset names: give at least one, or remove the setting to get the default"
  elif [[ "$GH_TOOLSETS" =~ [^a-z_,] ]]; then
    echo "GH_TOOLSETS must hold toolset names of a-z and _ only, got '$GH_TOOLSETS'"
  fi
}

mcp_start() {
  local srv_id i=0 o secrets=() f
  start_sidecar ab-mcp-github-srv \
    --network ab-egress \
    "${MCP_IMAGE[server]}" http
  # nginx resolves the server's name once, when it starts. The server's
  # container ID as a label makes start_sidecar recreate nginx whenever the
  # server was recreated (check-updates.sh, AB_RESTART), so it never sends
  # requests, with the PAT, to an old address.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-github-srv 2>/dev/null || true)"
  # One location per owner, each with its PAT in GH_PAT_<n>: the owner names
  # never go into the environment names.
  for o in ${MCP_ITEMS[GH_OWNERS]-}; do
    i=$((i + 1))
    secrets+=(--secret "${MCP_SECRET[pat_$o]},type=env,target=GH_PAT_$i")
  done
  f="$(github_nginx_template)" || exit 1
  start_sidecar ab-mcp-github \
    --network ab-internal --network ab-egress \
    --label "agentbox.upstream=$srv_id" \
    -e GH_TOOLSETS="$GH_TOOLSETS" \
    --secret "${MCP_SECRET[pat]},type=env,target=GH_PAT" \
    ${secrets[@]+"${secrets[@]}"} \
    --secret "${MCP_SECRET[mcp_caller]},type=env,target=GH_CALLER_TOKEN" \
    -v "$f:/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}

# nginx.conf.template with its account block (between the "account" marks)
# once for the github_pat token and once for each owner, at
# /o/<owner>/mcp with GH_PAT_<n>. Written into the cache of the sidecar;
# prints its path.
github_nginx_template() {
  local i=0 o block
  [[ -r "$MCP_DIR/nginx.conf.template" ]] || { ab_error "cannot read $MCP_DIR/nginx.conf.template"; return 1; }
  sidecar_dir ab-mcp-github >/dev/null || return 1
  block="$(sed -n '/# --- account ---/,/# --- end account ---/p' "$MCP_DIR/nginx.conf.template")"
  {
    sed '/# --- account ---/,$d' "$MCP_DIR/nginx.conf.template"
    printf '%s\n' "$block"
    for o in ${MCP_ITEMS[GH_OWNERS]-}; do
      i=$((i + 1))
      printf '%s\n' "$block" | sed "s#location = /mcp {#location = /o/$o/mcp {#; s#\${GH_PAT}#\${GH_PAT_$i}#"
    done
    sed '1,/# --- end account ---/d' "$MCP_DIR/nginx.conf.template"
  } | cache_write sidecars/ab-mcp-github default.conf.template
}
