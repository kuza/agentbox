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
# written anew with mode 600 and renamed into place; prints its path. Made
# again only when dbhub.toml, config.py or the agentbox image changed (their
# hash in dbhub.toml.src next to it): no container on a start without a
# change.
dbhub_config() {  # <dbhub.toml>
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/ab-mcp-dbhub" dst tmp src image_id in
  dst="$dir/dbhub.toml"
  [[ -r "$1" ]] || { echo "error: cannot read $1" >&2; return 1; }
  # Also the image that parses: another Python there could read it otherwise.
  image_id="$(podman image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)" && [[ -n "$image_id" ]] \
    || { echo "error: no image $IMAGE to read $1 with" >&2; return 1; }
  # One read of dbhub.toml for both the hash and the parse: saved in between,
  # a parse of the new file would be kept under the old file's hash.
  mkdir -p "$dir" && in="$(mktemp "$dir/input.XXXXXX")" || { echo "error: cannot write in $dir" >&2; return 1; }
  cat -- "$1" > "$in" || { rm -f -- "$in"; echo "error: cannot read $1" >&2; return 1; }
  src="$({ cat -- "$in" "$MCP_DIR/config.py"; echo "$image_id"; } | sha256sum | cut -c1-16)"
  if [[ -f "$dst" && "$(cat "$dst.src" 2>/dev/null)" == "$src" ]]; then
    rm -f -- "$in"
    printf '%s\n' "$dst"
    return 0
  fi
  tmp="$(mktemp "$dst.XXXXXX")" || { rm -f -- "$in"; echo "error: cannot write in $dir" >&2; return 1; }
  if ! podman run --rm -i --network none --entrypoint python3 "$IMAGE" \
         -I -c "$(cat "$MCP_DIR/config.py")" "$1" < "$in" > "$tmp"; then
    rm -f -- "$tmp" "$in"
    return 1
  fi
  rm -f -- "$in"
  if ! mv -f -- "$tmp" "$dst" || ! (umask 077; printf '%s\n' "$src" > "$dst.src"); then
    rm -f -- "$tmp"
    echo "error: cannot write $dst" >&2
    return 1
  fi
  printf '%s\n' "$dst"
}
