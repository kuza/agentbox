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
# module.toml holds the data of the module. Its checks keep the URL of the
# bb4 server and the egress host to the scheme, the host and the port.
mcp_start() {
  # bb4_devtools_build uses it too.
  local BB4_DEVTOOLS_IMAGE="localhost/agentbox-bb4-devtools" ws srv_id
  ab_warn "BB4 IS ON: THE AGENT DRIVES A BROWSER THAT REACHES THE WHOLE INTERNET, PAST THE EGRESS ALLOWLIST." \
          "IT CAN OPEN ANY SITE AND SEND YOUR CODE OR DATA ANYWHERE. TURN BB4 OFF WHEN THE AGENT DOES NOT NEED IT."

  # The browser's CDP WebSocket: same host as BB4_URL, wss for https.
  ws="ws"; [[ "${MCP_FIELD[BB4_URL.scheme]}" == https ]] && ws="wss"
  ws="$ws://${MCP_FIELD[BB4_URL.host]}:$BB4_DEVTOOLS_PORT/u/$BB4_USER/devtools/browser"

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
  ensure_caller_secret "${MCP_SECRET[bridge_key]}"
  #   --no-usage-statistics, --no-performance-crux: nothing to Google, not
  #   even the URLs of a performance trace (CrUX)
  #   --logLevel none: no page content in the sidecar's log
  start_sidecar ab-mcp-bb4-devtools \
    --network ab-egress \
    --secret "${MCP_SECRET[bridge_key]}" \
    "$BB4_DEVTOOLS_IMAGE" \
    --stdio "chrome-devtools-mcp --wsEndpoint=$ws --no-usage-statistics --no-performance-crux" \
    --outputTransport streamableHttp --stateful \
    --host 0.0.0.0 --port 8000 \
    --apiKeyFile "/run/secrets/${MCP_SECRET[bridge_key]}" --logLevel none
  # nginx resolves the server's name once, when it starts: recreated with
  # the server (its ID as a label), as in mcp/github.
  srv_id="$(podman inspect -f '{{.Id}}' ab-mcp-bb4-devtools 2>/dev/null || true)"
  start_sidecar ab-mcp-bb4 \
    --network ab-internal --network ab-egress \
    --label "agentbox.upstream=$srv_id" \
    --secret "${MCP_SECRET[mcp_caller]},type=env,target=BB4_CALLER_TOKEN" \
    --secret "${MCP_SECRET[bridge_key]},type=env,target=BB4_BRIDGE_KEY" \
    -v "$(sidecar_copy ab-mcp-bb4 "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}

# The image is built from devtools/: rebuilt when its Containerfile,
# package.json or package-lock.json change, and with AB_UPGRADE=1 (a newer
# base image; check-updates.sh says when the last one is a month old). Not
# in [images] of module.toml, which AB_UPGRADE pulls; agentbox uninstall
# removes it by its agentbox.build label.
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
