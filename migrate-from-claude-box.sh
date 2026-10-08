#!/usr/bin/env bash
# migrate-from-claude-box.sh: move an existing claude-box setup (cc-* resources)
# to agentbox (ab-* resources). Run once, on the host, with no sessions running.
#
# Copies, never moves: the old volumes, image and secret stay until you remove
# them yourself (commands are printed at the end). Safe to re-run: targets that
# already exist are left alone.
set -euo pipefail

OLD_IMAGE="localhost/claude-box"
USERNS="keep-id:uid=1000,gid=1000"

if ! podman image exists "$OLD_IMAGE"; then
  echo "error: $OLD_IMAGE not found; nothing to migrate (or it was already removed)" >&2
  exit 1
fi

# --- 0. no running sessions -------------------------------------------------
running="$(podman ps --format '{{.Names}}' | grep -E '^cc-(claude|pi)-[0-9]+$' || true)"
if [[ -n "$running" ]]; then
  echo "error: claude-box sessions still running, exit them first:" >&2
  echo "$running" >&2
  exit 1
fi

# --- 1. old sidecars and networks -------------------------------------------
echo "== removing old sidecars and networks"
for c in cc-egress cc-mcp-grafana cc-mcp-graylog cc-mcp-github cc-mcp-github-srv cc-llm-openai; do
  if podman container exists "$c"; then
    podman rm -f "$c" >/dev/null
    echo "   removed container $c"
  fi
done
for n in cc-internal cc-egress; do
  if podman network exists "$n"; then
    podman network rm "$n" >/dev/null
    echo "   removed network $n"
  fi
done

# --- 2. volumes ---------------------------------------------------------------
# copy_volume <old> <new> [paths to drop from the copy...]
copy_volume() {
  local old="$1" new="$2"; shift 2
  if ! podman volume exists "$old"; then
    echo "   skip $old (does not exist)"
    return 0
  fi
  if podman volume exists "$new"; then
    echo "   skip $new (already exists)"
    return 0
  fi
  podman volume create "$new" >/dev/null
  podman run --rm --network none --userns="$USERNS" \
    -v "$old:/from:ro" -v "$new:/to" \
    --entrypoint sh "$OLD_IMAGE" -c '
      set -eu
      cp -a /from/. /to/
      # Go module caches are read-only on purpose; make them removable first.
      for p in "$@"; do
        [ -e "/to/$p" ] || continue
        chmod -R u+w "/to/$p"
        rm -rf "/to/$p"
      done
    ' sh "$@"
  echo "   copied $old -> $new"
}

echo "== copying volumes"
# Claude's home: drop pi state (incl. a ChatGPT token) and caches that older
# versions kept there; they now live in their own volumes.
copy_volume cc-home  ab-claude-home  .pi .cache go .venvs
copy_volume pi-home  ab-pi-home      .cache go .venvs
copy_volume cc-cache ab-cache
copy_volume cc-go    ab-go

# --- 3. MCP URLs in Claude Code's registrations -----------------------------
echo "== rewriting MCP URLs in Claude Code's config"
if podman volume exists ab-claude-home; then
  podman run --rm --network none --userns="$USERNS" \
    -v ab-claude-home:/home/node \
    --entrypoint node "$OLD_IMAGE" -e '
      const fs = require("fs"), f = "/home/node/.claude.json";
      let s;
      try { s = fs.readFileSync(f, "utf8"); } catch (e) { console.log("   no ~/.claude.json"); process.exit(0); }
      const n = s.split("http://cc-mcp-").join("http://ab-mcp-");
      if (n === s) { console.log("   nothing to rewrite"); process.exit(0); }
      fs.writeFileSync(f, n, { mode: 0o600 });
      console.log("   rewrote " + (s.split("http://cc-mcp-").length - 1) + " URL(s)");'
fi

# --- 4. secrets -----------------------------------------------------------------
echo "== secrets"
if podman secret inspect cc_oauth >/dev/null 2>&1; then
  if podman secret inspect claude_oauth >/dev/null 2>&1; then
    echo "   skip claude_oauth (already exists)"
  else
    podman run --rm --network none --secret cc_oauth,type=env,target=T \
      --entrypoint sh "$OLD_IMAGE" -c 'printf %s "$T"' \
      | podman secret create claude_oauth - >/dev/null
    echo "   copied cc_oauth -> claude_oauth"
  fi
else
  echo "   skip (no cc_oauth)"
fi

cat <<'EOF'

== done
Next: start a session with ./run.sh (or ./pi.sh). The first run builds
localhost/agentbox, installs the agents and starts the ab-* sidecars.
Check /mcp in Claude Code and pi.

Environment variables are now AB_* instead of CC_* (AB_UPDATE, AB_RESTART,
AB_UPGRADE, ...). Update your aliases.

When everything works, remove the old resources:
  podman volume rm cc-home pi-home cc-tools pi-tools cc-cache cc-go
  podman rmi localhost/claude-box
  podman secret rm cc_oauth
EOF
