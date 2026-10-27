# The agent. Each agent is an npm package installed into its own tools volume,
# mounted read-only into the session (see agent_update), and has its own home
# volume: configs, sessions and credentials of one agent are not visible to,
# or writable by, the other. Only caches are shared (lib/session.sh).

agent_select() {
  AGENT="${AB_AGENT:-claude}"
  case "$AGENT" in
    claude)
      AGENT_PKG="@anthropic-ai/claude-code"
      AGENT_VOL="ab-claude-tools"; AGENT_PREFIX="/opt/claude"
      AGENT_HOME="ab-claude-home"
      # Its postinstall copies the native binary over a placeholder; npm 12
      # no longer runs dependency install scripts unless allowed.
      AGENT_INSTALL_FLAGS=(--allow-scripts=@anthropic-ai/claude-code)
      AGENT_SECRETS=(claude_oauth)
      # Egress group the agent cannot work without (lib/egress.sh).
      AGENT_EGRESS=(anthropic)
      ;;
    pi)
      AGENT_PKG="@earendil-works/pi-coding-agent"
      AGENT_VOL="ab-pi-tools"; AGENT_PREFIX="/opt/pi"
      AGENT_HOME="ab-pi-home"
      # As in pi's own container docs: no install scripts.
      AGENT_INSTALL_FLAGS=(--ignore-scripts)
      # No required secret: with a ChatGPT subscription pi signs in itself
      # (/login, stored in ab-pi-home); with an API key, openai_api_key enables
      # the ab-llm-openai sidecar.
      AGENT_SECRETS=()
      # Its hosts depend on the sign-in: the openai egress group for a
      # subscription, none for an API key.
      AGENT_EGRESS=()
      ;;
    shell)
      # No agent: bash in the same box, for looking around by hand and for
      # tests/escape.sh. Its own home volume, so nothing done here lands in
      # an agent's home.
      AGENT_PKG=""
      AGENT_VOL=""; AGENT_PREFIX=""
      AGENT_HOME="ab-shell-home"
      AGENT_INSTALL_FLAGS=()
      AGENT_SECRETS=()
      AGENT_EGRESS=()
      ;;
    *)
      echo "error: AB_AGENT must be 'claude', 'pi' or 'shell', got '$AGENT'" >&2
      exit 2
      ;;
  esac
  AGENT_BIN="$AGENT_PREFIX/bin/$AGENT"
  [[ "$AGENT" == shell ]] && AGENT_BIN=/bin/bash
  STAMP="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox.$AGENT.updated"
}

agent_check_secrets() {
  local s missing=() reply=""
  for s in ${AGENT_SECRETS[@]+"${AGENT_SECRETS[@]}"}; do
    podman secret inspect "$s" >/dev/null 2>&1 || missing+=("$s")
  done
  (( ${#missing[@]} )) || return 0
  # Only the Claude Code token is missing, and you are at a terminal: offer
  # the sign-in (agent_login, after Claude Code is installed).
  if [[ "${missing[*]}" == claude_oauth && -t 0 && -t 1 ]]; then
    echo "agentbox: no Claude Code token yet (podman secret claude_oauth)" >&2
    read -r -p "agentbox: get one now, with a sign-in in your browser? [Y/n] " reply || reply=n
    if [[ "$reply" != [nN]* ]]; then
      AGENT_NEEDS_LOGIN=1
      return 0
    fi
  fi
  echo "error: missing podman secrets: ${missing[*]} (agentbox login, or README, Setup in detail)" >&2
  exit 1
}

# A long-lived Claude Code token: `claude setup-token` in the box prints a
# URL; you sign in in your browser and paste the code shown there back into
# it; it prints the token, which you paste here (hidden). The browser's code
# is not the token, hence the prefix check. Stored as claude_oauth, replacing
# one that is there (also for a token that expired); running sessions keep
# the old one until they restart.
agent_login() {
  local token=""
  if [[ "$AGENT" != claude ]]; then
    echo "error: agentbox login gets a Claude Code token, but AB_AGENT is $AGENT" \
         "(pi signs in inside its session, /login; unset AB_AGENT for Claude Code)" >&2
    exit 2
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "error: agentbox login needs a terminal" >&2
    exit 2
  fi
  echo "agentbox: open the URL below, sign in, and paste the code from the browser back here" >&2
  if ! podman run --rm -it --network ab-egress --userns="$USERNS" \
       -v "$AGENT_VOL:$AGENT_PREFIX:ro" "$IMAGE" setup-token; then
    echo "error: claude setup-token failed; run agentbox login again and paste a fresh code" >&2
    exit 1
  fi
  echo "agentbox: now paste the token printed above (it starts with sk-ant-oat01-; the input is hidden)" >&2
  read -rsp "Claude token: " token || true
  # A token wrapped over several lines arrives as several lines in one
  # paste: take the lines that come right after the first.
  local more
  while IFS= read -rs -t 0.5 more; do token+="$more"; done
  echo >&2
  token="${token//[[:space:]]/}"
  if [[ "$token" != sk-ant-oat01-* ]]; then
    echo "error: that is not the token: it starts with sk-ant-oat01-, the code from the browser does not" \
         "(README, Token not picked up); nothing stored" >&2
    exit 1
  fi
  printf '%s' "$token" | secret_store claude_oauth
  echo "agentbox: token stored as the podman secret claude_oauth" >&2
}

# Runs in a short-lived container that HAS internet access but has neither the
# repo nor the agent. Installs into the agent's tools volume, which the session
# container mounts read-only, so the agent can't tamper with its own binary.
agent_update() {
  [[ -n "$AGENT_PKG" ]] || return 0
  mkdir -p "$(dirname "$STAMP")"
  if [[ "${AB_UPDATE:-}" == 1 || ! -f "$STAMP" ]] \
     || (( $(date +%s) - $(stat -c %Y "$STAMP") > UPDATE_EVERY )); then
    echo "agentbox: updating $AGENT..." >&2
    if podman run --rm --network ab-egress --userns="$USERNS" \
         -v "$AGENT_VOL:$AGENT_PREFIX" \
         --entrypoint npm "$IMAGE" \
         install -g ${AGENT_INSTALL_FLAGS[@]+"${AGENT_INSTALL_FLAGS[@]}"} --prefix "$AGENT_PREFIX" "$AGENT_PKG@latest" >&2; then
      touch "$STAMP"
    else
      echo "agentbox: warning: update failed, using the installed version" >&2
    fi
  fi
  if ! podman run --rm -v "$AGENT_VOL:$AGENT_PREFIX:ro" --entrypoint test "$IMAGE" -x "$AGENT_BIN"; then
    echo "error: $AGENT is not installed in the $AGENT_VOL volume (run with AB_UPDATE=1)" >&2
    exit 1
  fi
}

# Prepare the agent's home volume (one short-lived container, no network).
#
# 1. Ownership of mount-point parents. Read-only config and skills are
#    bind-mounted into ~/.claude or ~/.pi/agent. Podman creates missing parents
#    of a mount point as root, so on a fresh volume the agent could not write
#    its own config directory (e.g. pi failed to create ~/.pi/agent/sessions).
#    Create them as node first; chown also repairs volumes already affected.
#    Runs as root inside the user namespace: uid 0 there is a subuid on the
#    host, uid 1000 (node) is you.
#
# 2. Claude Code only: skip the first-run onboarding wizard. Interactive
#    Claude Code may ignore CLAUDE_CODE_OAUTH_TOKEN during onboarding and show
#    the browser login picker (anthropics/claude-code#46259). Setting
#    hasCompletedOnboarding in ~/.claude.json is the documented workaround.
#    Merges into the existing file, other settings are preserved. A file that
#    cannot be parsed (damaged, or caught mid-write) is left as it is.
#
# 3. Claude Code only: MCP servers registered by hand before the MCP modules
#    (`claude mcp add`, user scope) would duplicate the modules' servers.
#    A registration is removed only if both its name and its URL match an
#    enabled module (AB_MCP_MANAGED); anything else is left alone.
#
# 4. Claude Code only: defaults in ~/.claude/settings.json, each set only
#    while its key is absent, so an explicit choice there stays:
#    - autoMemoryEnabled false; a project enables it in .claude/settings.json;
#    - statusLine running claude/statusline.py, when that file exists.
#    An unreadable settings file is left alone.
agent_prepare_home() {
  local home_dirs=()
  case "$AGENT" in
    claude) home_dirs=(.claude) ;;
    pi)     home_dirs=(.pi .pi/agent) ;;
  esac
  STATUSLINE=""
  [[ -f "$SCRIPT_DIR/claude/statusline.py" ]] && STATUSLINE=1
  podman run --rm --network none --userns="$USERNS" --user 0 \
    -e AGENT="$AGENT" \
    -e AB_STATUSLINE="$STATUSLINE" \
    -e AB_MCP_MANAGED="$MCP_MANAGED" \
    -v "$AGENT_HOME:/home/node" \
    --entrypoint sh "$IMAGE" -c '
      set -eu
      cd /home/node
      for d in "$@"; do
        mkdir -p "$d"
        chown node:node "$d"
      done
      if [ "$AGENT" = claude ]; then
        node -e "
          const fs = require(\"fs\"), f = \"/home/node/.claude.json\";
          let c = {}, changed = false, readable = true;
          try { c = JSON.parse(fs.readFileSync(f, \"utf8\")); } catch (e) {
            readable = e.code === \"ENOENT\";
            if (!readable) console.error(\"agentbox: warning: ~/.claude.json cannot be read (\" + e.message + \"); left as it is\");
          }
          if (!readable || !c || typeof c !== \"object\") { c = {}; readable = false; }
          if (c.hasCompletedOnboarding !== true) {
            c.hasCompletedOnboarding = true;
            changed = true;
          }
          for (const line of (process.env.AB_MCP_MANAGED || \"\").split(\"\\n\")) {
            const [name, url] = line.split(\" \");
            const s = c.mcpServers && c.mcpServers[name];
            if (name && s && s.url === url) {
              delete c.mcpServers[name];
              changed = true;
              console.error(\"agentbox: removed the old \" + name + \" MCP registration, now provided by its module\");
            }
          }
          if (changed && readable) fs.writeFileSync(f, JSON.stringify(c, null, 2), { mode: 0o600 });
          const s = \"/home/node/.claude/settings.json\";
          let t = {}, ok = true;
          try { t = JSON.parse(fs.readFileSync(s, \"utf8\")); } catch (e) { ok = e.code === \"ENOENT\"; }
          const d = { autoMemoryEnabled: false };
          if (process.env.AB_STATUSLINE) {
            d.statusLine = { type: \"command\", command: \"python3 /home/node/.claude/statusline.py\" };
          }
          if (ok && t && typeof t === \"object\") {
            const add = Object.keys(d).filter((k) => t[k] === undefined);
            for (const k of add) t[k] = d[k];
            if (add.length) fs.writeFileSync(s, JSON.stringify(t, null, 2));
          }"
        chown node:node /home/node/.claude.json /home/node/.claude/settings.json
      fi
    ' sh ${home_dirs[@]+"${home_dirs[@]}"}
}
