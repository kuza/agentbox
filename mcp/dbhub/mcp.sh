# DBHub: SQL databases (PostgreSQL, MySQL, SQL Server, ...) through
# bytebase/dbhub, read only. You list the databases in <AB_HOME>/dbhub.toml
# ([[sources]] with their DSNs and passwords, mode 600, like ~/.pgpass).
# DBHub does not read that file: config.py parses it and writes DBHub's own,
# the sources plus a read-only execute_sql and search_objects for each, to
# the cache (mode 600), mounted into the sidecar. The session never gets the
# passwords; agents authenticate to the sidecar with the caller token.
# module.toml holds the data of the module.
#
# The environment of the DBHub container (not settings of the module):
#   DBHUB_AUTH_TOKEN     callers must send "Authorization: Bearer <token>"
#   DBHUB_ALLOWED_HOSTS  DNS-rebinding protection: only the Host the agent sends
mcp_start() {
  local src="$AB_HOME_DIR/dbhub.toml" f
  # Deleted or refused, say to take access away: exit "$MCP_TAKE_AWAY", and the sidecar of
  # the last start goes with its copy of the passwords (lib/mcp.sh).
  if [[ ! -f "$src" ]]; then
    ab_error "the dbhub module needs $src, a [[sources]] entry per database (README, DBHub (MCP))"
    exit "$MCP_TAKE_AWAY"
  fi
  if [[ -n "$(find -L "$src" -perm /077 2>/dev/null)" ]]; then
    ab_warn "$src holds database passwords and the group or others may read it: chmod 600 $src"
  fi
  f="$(dbhub_config "$src")" || exit "$MCP_TAKE_AWAY"
  start_sidecar ab-mcp-dbhub \
    --network ab-internal --network ab-egress \
    --secret "${MCP_SECRET[mcp_caller]},type=env,target=DBHUB_AUTH_TOKEN" \
    -e DBHUB_ALLOWED_HOSTS=ab-mcp-dbhub \
    -v "$f:/etc/dbhub/dbhub.toml:ro,Z" \
    "${MCP_IMAGE[server]}" \
    --transport http --port 8080 --config /etc/dbhub/dbhub.toml
}

# DBHub's config from <dbhub.toml>, by config.py in the agentbox image,
# written anew with mode 600 and renamed into place; prints its path. Made
# again only when dbhub.toml, config.py or the agentbox image changed (their
# hash in dbhub.toml.src next to it): no container on a start without a
# change.
dbhub_config() {  # <dbhub.toml>
  local dir dst tmp src image_id in
  dir="$(sidecar_dir ab-mcp-dbhub)" || return 1
  dst="$dir/dbhub.toml"
  [[ -r "$1" ]] || { ab_error "cannot read $1"; return 1; }
  # Also the image that parses: another Python there could read it otherwise.
  agentbox_image_id || { ab_error "no image $IMAGE to read $1 with"; return 1; }
  image_id="$AGENTBOX_IMAGE_ID"
  # One read of dbhub.toml for both the hash and the parse: saved in between,
  # a parse of the new file would be kept under the old file's hash.
  in="$(mktemp "$dir/input.XXXXXX")" || { ab_error "cannot write in $dir"; return 1; }
  cat -- "$1" > "$in" || { rm -f -- "$in"; ab_error "cannot read $1"; return 1; }
  src="$({ cat -- "$in" "$MCP_DIR/config.py"; echo "$image_id"; } | sha256sum | cut -c1-16)"
  if [[ -f "$dst" && "$(cat "$dst.src" 2>/dev/null)" == "$src" ]]; then
    rm -f -- "$in"
    printf '%s\n' "$dst"
    return 0
  fi
  tmp="$(mktemp "$dst.XXXXXX")" || { rm -f -- "$in"; ab_error "cannot write in $dir"; return 1; }
  # Its messages (what is wrong with dbhub.toml) become the reason the
  # warning before the session gives.
  # The messages may quote dbhub.toml: mode 600, like the rest.
  if ! (umask 077; podman run --rm -i --network none --entrypoint python3 "$IMAGE" \
         -I -c "$(cat "$MCP_DIR/config.py")" "$1" < "$in" > "$tmp" 2> "$in.err"); then
    # All of it on the terminal; the first lines are the reason.
    cat -- "$in.err" >&2
    [[ ! -s "$in.err" ]] || ab_reason "$(sed 's/^error: //; s/^Error: //' "$in.err" | head -3 | paste -sd ';' -)"
    rm -f -- "$tmp" "$in" "$in.err"
    return 1
  fi
  cat -- "$in.err" >&2
  rm -f -- "$in" "$in.err"
  if ! mv -f -- "$tmp" "$dst" || ! (umask 077; printf '%s\n' "$src" > "$dst.src"); then
    rm -f -- "$tmp"
    ab_error "cannot write $dst"
    return 1
  fi
  printf '%s\n' "$dst"
}
