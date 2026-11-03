# bb4: a remote browser the agent drives, one per user on a browser
# server (README, Remote browser (bb4)). Two MCP servers:
#   bb4              the server's own, which starts the browser and sets it
#                    up; remote, reached through squid, like context7
#   bb4-devtools     pages in that browser (open, read, click, screenshots):
#                    chrome-devtools-mcp, stdio only, behind supergateway in
#                    the sidecar ab-mcp-bb4-devtools, built here
#                    (devtools/Containerfile); it reaches the browser's CDP
#                    WebSocket directly over ab-egress. nginx ab-mcp-bb4
#                    checks the caller token, as for the other modules.
# The browser server tells users apart by the name in the path and has
# no authentication of its own. The browser goes to the internet itself,
# past squid's allowlist, so every start warns.
MCP_DESCRIPTION="A remote browser on the browser server"
MCP_CONFIG=(BB4_URL BB4_USER BB4_DEVTOOLS_PORT)
MCP_REQUIRED_CONFIG=(BB4_URL BB4_USER)
MCP_CALLER_SECRET=bb4_mcp_caller
MCP_OWN_SECRETS=(bb4_bridge_key)
BB4_DEVTOOLS_IMAGE="localhost/agentbox-bb4-devtools"

#   BB4_URL            the server's MCP base URL, scheme, host and port only
#                      (http://browser.example.internal:5101)
#   BB4_USER           your user name there (your GitHub user name)
#   BB4_DEVTOOLS_PORT  the port of its DevTools (CDP) WebSocket on the same
#                      host (default: 5100)
# Checked once, here. BB4_TARGET: the host and port squid lets the agent
# reach, from BB4_URL; empty for a URL not of the form above (a path, an
# odd host or port), which then adds nothing to squid. mcp_check says what
# is wrong.
BB4_TARGET=""
BB4_LABEL='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
if [[ "${BB4_URL:-}" =~ ^https?://(($BB4_LABEL\.)*$BB4_LABEL)(:([1-9][0-9]{0,4}))?/?$ ]]; then
  if (( ${BASH_REMATCH[6]:-0} <= 65535 )); then
    BB4_TARGET="${BASH_REMATCH[1]}${BASH_REMATCH[6]:+:${BASH_REMATCH[6]}}"
  fi
fi
BB4_USER_RE='^[A-Za-z0-9][A-Za-z0-9-]*$'
BB4_PORT="${BB4_DEVTOOLS_PORT:-5100}"
# Only from settings that check out: a URL of other ones could break the
# server line (lib/mcp.sh).
MCP_URL="http://invalid/u/x/mcp"
if [[ -n "$BB4_TARGET" && "${BB4_USER:-}" =~ $BB4_USER_RE ]]; then
  MCP_URL="${BB4_URL%/}/u/$BB4_USER/mcp"
fi
MCP_SERVERS=(
  "bb4|$MCP_URL|-|The remote browser on the browser server: start it, set it up"
  "bb4-devtools|http://ab-mcp-bb4:8080/mcp|caller|Pages in the remote browser: open, read, click, type, screenshots"
)
MCP_EGRESS=()
[[ -z "$BB4_TARGET" ]] || MCP_EGRESS=("$BB4_TARGET")

# Settings that do not check out take the browser away (lib/mcp.sh): the
# sidecar of the old ones would keep driving that browser for open sessions.
mcp_check() {
  [[ -n "$BB4_TARGET" ]] \
    || echo "BB4_URL must be http:// or https://, a host and an optional port, nothing else, got '${BB4_URL:-}'"
  [[ "${BB4_USER:-}" =~ $BB4_USER_RE ]] \
    || echo "BB4_USER must be a user name (letters, digits, -), got '${BB4_USER:-}'"
  [[ "$BB4_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( BB4_PORT <= 65535 )) \
    || echo "BB4_DEVTOOLS_PORT must be a port, got '$BB4_PORT'"
}

mcp_start() {
  local ws srv_id
  ab_warn "BB4 IS ON: THE AGENT DRIVES A BROWSER THAT REACHES THE WHOLE INTERNET, PAST THE EGRESS ALLOWLIST." \
          "IT CAN OPEN ANY SITE AND SEND YOUR CODE OR DATA ANYWHERE. TURN BB4 OFF WHEN THE AGENT DOES NOT NEED IT."

  # The browser's CDP WebSocket: same host as BB4_URL, wss for https.
  ws="ws"; [[ "$BB4_URL" == https://* ]] && ws="wss"
  ws="$ws://${BB4_TARGET%%:*}:$BB4_PORT/u/$BB4_USER/devtools/browser"

  if [[ ! -f "$MCP_DIR/devtools/package-lock.json" ]]; then
    ab_error "mcp/bb4/devtools/package-lock.json is missing: in a clone, run" \
             "(cd mcp/bb4/devtools && npm install --package-lock-only --ignore-scripts)" \
             "on the host (README, Remote browser (bb4))"
    exit 1
  fi
  if [[ "${AB_UPGRADE:-}" == 1 ]]; then
    image_retire "$BB4_DEVTOOLS_IMAGE"
    bb4_devtools_build --pull
  else
    image_ensure "$BB4_DEVTOOLS_IMAGE" "$(bb4_devtools_fingerprint)" bb4_devtools_build
  fi

  # A random key between nginx and supergateway, made once.
  ensure_caller_secret bb4_bridge_key
  #   --no-usage-statistics, --no-performance-crux: nothing to Google, not
  #   even the URLs of a performance trace (CrUX)
  #   --logLevel none: no page content in the sidecar's log
  start_sidecar ab-mcp-bb4-devtools \
    --network ab-egress \
    --secret bb4_bridge_key \
    "$BB4_DEVTOOLS_IMAGE" \
    --stdio "chrome-devtools-mcp --wsEndpoint=$ws --no-usage-statistics --no-performance-crux" \
    --outputTransport streamableHttp --stateful \
    --host 0.0.0.0 --port 8000 \
    --apiKeyFile /run/secrets/bb4_bridge_key --logLevel none
  # nginx resolves the server's name once, when it starts: recreated with
  # the server (its ID as a label), as in mcp/github.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-bb4-devtools 2>/dev/null || true)"
  start_sidecar ab-mcp-bb4 \
    --network ab-internal --network ab-egress \
    --label "agentbox.upstream=$srv_id" \
    --secret bb4_mcp_caller,type=env,target=BB4_CALLER_TOKEN \
    --secret bb4_bridge_key,type=env,target=BB4_BRIDGE_KEY \
    -v "$(sidecar_copy ab-mcp-bb4 "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}

# The image is built from devtools/: rebuilt when its Containerfile,
# package.json or package-lock.json change, and with AB_UPGRADE=1 (a newer
# base image; check-updates.sh says when the last one is a month old). Not
# in MCP_IMAGES, which AB_UPGRADE pulls; agentbox uninstall removes it by
# its agentbox.build label.
bb4_devtools_fingerprint() {
  image_fingerprint "$MCP_DIR/devtools/Containerfile" \
    "$(cat -- "$MCP_DIR/devtools/package.json" "$MCP_DIR/devtools/package-lock.json")"
}

bb4_devtools_build() {  # [podman build options...]
  echo "agentbox: building $BB4_DEVTOOLS_IMAGE (chrome-devtools-mcp)..." >&2
  if ! build_local "$BB4_DEVTOOLS_IMAGE" "$MCP_DIR/devtools/Containerfile" "$(bb4_devtools_fingerprint)" \
         "$MCP_DIR/devtools" "$@"; then
    ab_error "could not build $BB4_DEVTOOLS_IMAGE (it needs the npm registry once)"
    exit 1
  fi
}
