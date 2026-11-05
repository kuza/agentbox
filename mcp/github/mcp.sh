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
MCP_DESCRIPTION="GitHub pull requests, issues, CI runs and repository contents"
MCP_CONFIG=(GH_TOOLSETS GH_OWNERS)
MCP_CALLER_SECRET=github_mcp_caller
MCP_IMAGES=(ghcr.io/github/github-mcp-server:latest "$IMG_NGINX")
# The owner secrets have names from GH_OWNERS: agentbox uninstall --all
# removes github_pat_<owner> for the owners in config.env.
MCP_SECRETS_BY_SETTING=("GH_OWNERS github_pat_")

#   GH_TOOLSETS   toolsets nginx pins (default below)
#   GH_OWNERS     more resource owners, each with its own PAT (optional)
# The owners, lowercase (GitHub names do not depend on case), once each.
GH_OWNER_LIST=()
GH_OWNERS_BAD=""
IFS=', ' read -ra _l <<<"${GH_OWNERS:-}"
for _t in ${_l[@]+"${_l[@]}"}; do
  _o="${_t,,}"
  # A GitHub user or organization name: letters, digits and single hyphens,
  # not at the start or the end, at most 39 characters.
  if [[ ! "$_o" =~ ^[a-z0-9]([a-z0-9]|-[a-z0-9])*$ || ${#_o} -gt 39 ]]; then
    GH_OWNERS_BAD+=" $_t"
    continue
  fi
  [[ " ${GH_OWNER_LIST[*]-} " == *" $_o "* ]] || GH_OWNER_LIST+=("$_o")
done
unset _o _t _l

MCP_SECRETS=(github_pat)
MCP_SECRET_HELP=("github_pat: a fine-grained personal access token, read-only (README, GitHub (MCP))")
MCP_SERVERS=("github|http://ab-mcp-github:8080/mcp|caller|GitHub: pull requests, issues, CI runs and contents of the repositories of the github_pat token")
for _o in ${GH_OWNER_LIST[@]+"${GH_OWNER_LIST[@]}"}; do
  MCP_SECRETS+=("github_pat_$_o")
  MCP_SECRET_HELP+=("github_pat_$_o: a fine-grained personal access token with resource owner $_o, read-only (README, GitHub (MCP))")
  MCP_SERVERS+=("github-$_o|http://ab-mcp-github:8080/o/$_o/mcp|caller|GitHub: pull requests, issues, CI runs and contents of the repositories of $_o")
done
unset _o

mcp_check() {
  [[ -z "$GH_OWNERS_BAD" ]] \
    || echo "GH_OWNERS must hold GitHub user or organization names, got:$GH_OWNERS_BAD"
}

mcp_start() {
  local srv_id i=0 o secrets=() f
  start_sidecar ab-mcp-github-srv \
    --network ab-egress \
    ghcr.io/github/github-mcp-server:latest http
  # nginx resolves the server's name once, when it starts. The server's
  # container ID as a label makes start_sidecar recreate nginx whenever the
  # server was recreated (check-updates.sh, AB_RESTART), so it never sends
  # requests, with the PAT, to an old address.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-github-srv 2>/dev/null || true)"
  # One location per owner, each with its PAT in GH_PAT_<n>: the owner names
  # never go into the environment names.
  for o in ${GH_OWNER_LIST[@]+"${GH_OWNER_LIST[@]}"}; do
    i=$((i + 1))
    secrets+=(--secret "github_pat_$o,type=env,target=GH_PAT_$i")
  done
  f="$(github_nginx_template)" || exit 1
  start_sidecar ab-mcp-github \
    --network ab-internal --network ab-egress \
    --label "agentbox.upstream=$srv_id" \
    -e GH_TOOLSETS="${GH_TOOLSETS:-context,repos,issues,pull_requests,actions}" \
    --secret github_pat,type=env,target=GH_PAT \
    ${secrets[@]+"${secrets[@]}"} \
    --secret github_mcp_caller,type=env,target=GH_CALLER_TOKEN \
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
    for o in ${GH_OWNER_LIST[@]+"${GH_OWNER_LIST[@]}"}; do
      i=$((i + 1))
      printf '%s\n' "$block" | sed "s#location = /mcp {#location = /o/$o/mcp {#; s#\${GH_PAT}#\${GH_PAT_$i}#"
    done
    sed '1,/# --- end account ---/d' "$MCP_DIR/nginx.conf.template"
  } | cache_write sidecars/ab-mcp-github default.conf.template
}
