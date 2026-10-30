# DBHub: SQL databases (PostgreSQL, MySQL, SQL Server, ...) through
# bytebase/dbhub, read only. You list the databases in <AB_HOME>/dbhub.toml
# ([[sources]] with their DSNs and passwords, mode 600, like ~/.pgpass).
# DBHub does not read that file: config.py parses it and writes DBHub's own,
# the sources plus a read-only execute_sql and search_objects for each, to
# the cache (mode 600), mounted into the sidecar. The session never gets the
# passwords; agents authenticate to the sidecar with the caller token.
MCP_DESCRIPTION="SQL databases listed in dbhub.toml: schemas and queries (read-only)"
MCP_URL="http://ab-mcp-dbhub:8080/mcp"
MCP_CALLER_SECRET=dbhub_mcp_caller
DBHUB_IMAGE="docker.io/bytebase/dbhub:1.5.0"
MCP_IMAGES=("$DBHUB_IMAGE")

#   DBHUB_AUTH_TOKEN     callers must send "Authorization: Bearer <token>"
#   DBHUB_ALLOWED_HOSTS  DNS-rebinding protection: only the Host the agent sends
mcp_start() {
  local src="$AB_HOME_DIR/dbhub.toml" f
  if [[ ! -f "$src" ]]; then
    dbhub_stop
    echo "error: the dbhub module needs $src, a [[sources]] entry per database (README, DBHub (MCP))" >&2
    exit 1
  fi
  if [[ -n "$(find -L "$src" -perm /077 2>/dev/null)" ]]; then
    echo "agentbox: warning: $src holds database passwords and the group or others may read it: chmod 600 $src" >&2
  fi
  f="$(dbhub_config "$src")" || { dbhub_stop; exit 1; }
  start_sidecar ab-mcp-dbhub \
    --network ab-internal --network ab-egress \
    --secret dbhub_mcp_caller,type=env,target=DBHUB_AUTH_TOKEN \
    -e DBHUB_ALLOWED_HOSTS=ab-mcp-dbhub \
    -v "$f:/etc/dbhub/dbhub.toml:ro,Z" \
    "$DBHUB_IMAGE" \
    --transport http --port 8080 --config /etc/dbhub/dbhub.toml
}

# A dbhub.toml deleted or broken, say to take access away: the sidecar of the
# last start and its copy with the passwords go, not left serving them.
dbhub_stop() {
  podman rm -f ab-mcp-dbhub >/dev/null 2>&1 || true
  rm -rf -- "${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/ab-mcp-dbhub"
}

# DBHub's config from <dbhub.toml>, by config.py in the agentbox image,
# written anew with mode 600 and renamed into place; prints its path.
dbhub_config() {  # <dbhub.toml>
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/ab-mcp-dbhub" dst tmp
  dst="$dir/dbhub.toml"
  mkdir -p "$dir" && tmp="$(mktemp "$dst.XXXXXX")" || { echo "error: cannot write in $dir" >&2; return 1; }
  if ! podman run --rm -i --network none --entrypoint python3 "$IMAGE" \
         -I -c "$(cat "$MCP_DIR/config.py")" "$1" < "$1" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    echo "error: cannot write $dst" >&2
    return 1
  fi
  printf '%s\n' "$dst"
}
