# Tabularis (https://tabularis.dev): the database connections you saved in
# the Tabularis desktop app, through its built-in MCP server (README,
# Tabularis (MCP)). `tabularis --mcp` speaks stdio only and needs what the app
# has on the host: the saved connections, the system keychain, and the open
# app window, where writes are approved. So it runs on the host:
#
#   agentbox-mcp-tabularis  host service (start_host_unit): supergateway,
#                           installed from bridge/package-lock.json, serves
#                           Streamable HTTP on 127.0.0.1:TABULARIS_PORT,
#                           starts one `tabularis --mcp` per MCP session and
#                           requires the bridge key
#   ab-mcp-tabularis-relay  socat on the host network: a unix socket in the
#                           volume ab-mcp-tabularis-sock, forwarded to
#                           127.0.0.1:TABULARIS_PORT. A container holds the
#                           socket because SELinux stops containers from
#                           connecting to one a host process holds
#   ab-mcp-tabularis        nginx on ab-internal only: checks the caller
#                           token, replaces it with the bridge key and
#                           forwards to the socket (nginx.conf.template)
#
# Tabularis writes every query and its result to stderr: it goes to
# /dev/null, and supergateway logs nothing, so no data lands in the journal.
MCP_DESCRIPTION="Databases from your Tabularis connections: schemas and SQL queries"
MCP_URL="http://ab-mcp-tabularis:8080/mcp"
MCP_CONFIG=(TABULARIS_CMD TABULARIS_PORT)
MCP_OWN_SECRETS=(tabularis_bridge_key)
MCP_CALLER_SECRET=tabularis_mcp_caller
MCP_IMAGES=("$IMG_NGINX")

# supergateway and every package under it, at the versions and hashes of
# bridge/package-lock.json: npm ci checks each package against its hash and
# runs no install scripts. One directory per lock file in the cache;
# maintainers update the lock with
#   cd mcp/tabularis/bridge && npm install --package-lock-only --ignore-scripts

#   TABULARIS_CMD      runs Tabularis, --mcp is appended (default: tabularis)
#   TABULARIS_PORT     supergateway's port on 127.0.0.1 (default: 47821)
#   AB_TABULARIS_WAIT  seconds to wait for supergateway to listen (default: 60)
# Both settings end up in a systemd command line, which expands $ and %:
# only plain characters are accepted.
mcp_start() {
  local cmd="${TABULARIS_CMD:-tabularis}" port="${TABULARIS_PORT:-47821}"
  local wait="${AB_TABULARIS_WAIT:-60}" plain='^[A-Za-z0-9_./:=+ -]+$'
  local node npm tab key bridge image_id i state
  if [[ ! "$cmd" =~ $plain || "$cmd" == " "* ]]; then
    echo "error: TABULARIS_CMD may hold only letters, digits, spaces and _./:=+-, and starts with the command, got '$cmd'" >&2
    exit 2
  fi
  # The service runs in your home directory, not here: a relative path
  # would point elsewhere.
  if [[ "${cmd%% *}" == */* && "${cmd%% *}" != /* ]]; then
    echo "error: TABULARIS_CMD: give the command by name or as an absolute path, got '${cmd%% *}'" >&2
    exit 2
  fi
  if [[ ! "$port" =~ ^[1-9][0-9]*$ ]] || (( port < 1024 || port > 65535 )); then
    echo "error: TABULARIS_PORT must be a port from 1024 to 65535, got '$port'" >&2
    exit 2
  fi
  if [[ ! "$wait" =~ ^[0-9]+$ ]]; then
    echo "error: AB_TABULARIS_WAIT must be a number of seconds, got '$wait'" >&2
    exit 2
  fi
  if ! host_units_available; then
    echo "error: the tabularis module needs a systemd user session on the host (systemctl --user);" \
         "over SSH it needs lingering (README, Tabularis (MCP))" >&2
    exit 1
  fi
  if ! command -v ss >/dev/null; then
    echo "error: the tabularis module needs ss (iproute2) on the host, to see who listens on TABULARIS_PORT" >&2
    exit 1
  fi
  if ! node="$(command -v node)" || ! npm="$(command -v npm)"; then
    echo "error: the tabularis module needs Node.js (node and npm) on the host (README, Tabularis (MCP))" >&2
    exit 1
  fi
  if ! tab="$(command -v "${cmd%% *}")"; then
    echo "error: TABULARIS_CMD: '${cmd%% *}' not found; install Tabularis or set TABULARIS_CMD (README, Tabularis (MCP))" >&2
    exit 1
  fi

  # The bridge key: supergateway reads it from this file, nginx gets it as a
  # secret. The file is the original: made when it is missing, and copied
  # into the secret when the key is new, the secret is missing, or with
  # AB_RESTART=1 (after you changed the secret by hand).
  key="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/tabularis/bridge.key"
  if [[ ! -f "$MCP_DIR/bridge/package.json" || ! -f "$MCP_DIR/bridge/package-lock.json" ]]; then
    echo "error: the tabularis module lacks bridge/package.json or bridge/package-lock.json in $MCP_DIR" >&2
    exit 1
  fi
  bridge="$(tabularis_bridge_dir)"
  if [[ ! "$key$node$tab$bridge" =~ $plain ]]; then
    echo "error: the tabularis module cannot use paths with characters other than letters, digits, spaces and _./:=+- ($key, $node, $tab, $bridge)" >&2
    exit 2
  fi
  if [[ ! -s "$key" ]] && tabularis_new_key "$key"; then
    secret_store tabularis_bridge_key < "$key"
    echo "agentbox: created the tabularis bridge key" >&2
  elif [[ "${AB_RESTART:-}" == 1 ]] || ! podman secret inspect tabularis_bridge_key >/dev/null 2>&1; then
    secret_store tabularis_bridge_key < "$key"
  fi

  tabularis_fail_if_taken "$port"

  if [[ ! -x "$bridge/node_modules/.bin/supergateway" ]] && ! tabularis_install_bridge "$npm" "$bridge"; then
    echo "error: could not install the tabularis bridge: npm ci failed (see above; it needs the npm" \
         "registry). Remove tabularis from AB_MCP to start without it (README, Tabularis (MCP))." >&2
    exit 1
  fi
  # In use: its date keeps it from tabularis_prune_bridges.
  touch -- "$bridge"

  # supergateway's command starts with #!/usr/bin/env node: node in PATH.
  start_host_unit agentbox-mcp-tabularis "PATH=${node%/*}:${tab%/*}:/usr/local/bin:/usr/bin:/bin" -- \
    "$bridge/node_modules/.bin/supergateway" \
    --stdio "$cmd --mcp 2>/dev/null" \
    --outputTransport streamableHttp --stateful \
    --host 127.0.0.1 --port "$port" \
    --apiKeyFile "$key" --logLevel none
  tabularis_prune_bridges

  # The sidecars only once supergateway listens, or with a warning when it
  # does not yet: then the agent's requests fail, but go nowhere else.
  # A bridge that gave up (start limit, lib/sidecars.sh) is not waited for.
  for (( i = 0; i < wait; i++ )); do
    tabularis_listening "$port" && break
    tabularis_fail_if_taken "$port"
    state="$(systemctl --user is-active agentbox-mcp-tabularis.service 2>/dev/null || true)"
    [[ "$state" == active || "$state" == activating ]] || break
    (( i == 2 )) && echo "agentbox: waiting for the tabularis bridge" >&2
    sleep 1
  done
  if ! tabularis_listening "$port"; then
    echo "agentbox: warning: the tabularis bridge does not answer on 127.0.0.1:$port;" \
         "see systemctl --user status agentbox-mcp-tabularis (README, Tabularis (MCP))" >&2
  fi

  # Root inside the user namespace (your user on the host) to own the
  # socket; no capability, read-only. The image ID label makes start_sidecar
  # recreate it on a rebuilt image.
  image_id="$(podman image inspect -f '{{.Id}}' "$IMAGE")"
  start_sidecar ab-mcp-tabularis-relay \
    --network host \
    --label "agentbox.image=$image_id" \
    --user=0 --cap-drop=ALL --security-opt=no-new-privileges --read-only \
    -v ab-mcp-tabularis-sock:/run/tabularis \
    --entrypoint=socat "$IMAGE" \
    "UNIX-LISTEN:/run/tabularis/mcp.sock,fork,mode=666,unlink-early" "TCP:127.0.0.1:$port"

  # The key's hash as a label recreates nginx when the key was made anew.
  start_sidecar ab-mcp-tabularis \
    --network ab-internal \
    --label "agentbox.bridge=$(sha256sum < "$key" | cut -c1-16)" \
    --secret tabularis_mcp_caller,type=env,target=TABULARIS_CALLER_TOKEN \
    --secret tabularis_bridge_key,type=env,target=TABULARIS_BRIDGE_KEY \
    -v ab-mcp-tabularis-sock:/run/tabularis \
    -v "$(sidecar_copy ab-mcp-tabularis "$MCP_DIR/nginx.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}

# Where the bridge of this package.json and package-lock.json is installed:
# both decide what npm ci installs (the overrides are in package.json).
tabularis_bridge_dir() {
  echo "${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/tabularis/bridge-$(cat -- "$MCP_DIR/bridge/package.json" "$MCP_DIR/bridge/package-lock.json" | sha256sum | cut -c1-16)"
}

# Installs the lock file's packages into <dir>; 1 if that fails. It works
# in a directory of its own, moved into place once complete, so that an
# interrupted install leaves nothing that looks done; such leftovers go
# after an hour.
tabularis_install_bridge() {  # <npm> <dir>
  local base="${2%/*}" tmp
  echo "agentbox: installing the tabularis bridge (supergateway, from mcp/tabularis/bridge/package-lock.json)" >&2
  mkdir -p "$base" || return 1
  find "$base" -maxdepth 1 -name '.install.*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  tmp="$(mktemp -d "$base/.install.XXXXXX")" || return 1   # not bridge-*
  if ! cp -- "$MCP_DIR/bridge/package.json" "$MCP_DIR/bridge/package-lock.json" "$tmp/"; then
    rm -rf -- "$tmp"
    return 1
  fi
  # npm's summary on stdout is dropped; its errors still show.
  if ! (cd "$tmp" || exit 1; "$1" ci --ignore-scripts --omit=dev --no-audit --no-fund --loglevel=error) >/dev/null \
     || [[ ! -x "$tmp/node_modules/.bin/supergateway" ]]; then
    rm -rf -- "$tmp"
    return 1
  fi
  # Another start may have finished the same install meanwhile: that one
  # stays. A target without supergateway (left half done) is replaced.
  if ! mv -T -- "$tmp" "$2" 2>/dev/null; then
    if [[ -x "$2/node_modules/.bin/supergateway" ]]; then
      rm -rf -- "$tmp"
    elif ! { rm -rf -- "$2" && mv -T -- "$tmp" "$2"; }; then
      rm -rf -- "$tmp"
      return 1
    fi
  fi
}

# Removes the installs no start has used for 30 days: those of earlier lock
# files. One another agentbox copy still uses (a clone next to an installed
# release) stays, as its starts keep it fresh.
tabularis_prune_bridges() {
  find "${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/tabularis" -mindepth 1 -maxdepth 1 \
       -name 'bridge-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true
}

# A new key in <file>, made with mode 600 and linked into place: of two
# starts at the same time only one makes it, and both then read that one.
# An empty file left over is replaced.
tabularis_new_key() {  # <file>: 0 if this start made the key
  local tmp made=1
  mkdir -p "${1%/*}"
  chmod 700 "${1%/*}"
  [[ -e "$1" && ! -s "$1" ]] && rm -f -- "$1"
  tmp="$(mktemp "$1.XXXXXX")"
  random_token > "$tmp"
  ln -- "$tmp" "$1" 2>/dev/null && made=0
  rm -f -- "$tmp"
  return "$made"
}

# Who listens on 127.0.0.1:<port>: ss shows the process of each listening
# socket you own; the bridge's processes are those in its service's cgroup.
# The cgroup is in one of three places: cgroup v2, the v2 part of a hybrid
# host, or systemd's own v1 hierarchy.
tabularis_listening() {  # <port>: 0 if the bridge listens on it
  local cg f procs="" pid
  cg="$(systemctl --user show -p ControlGroup --value agentbox-mcp-tabularis.service 2>/dev/null)"
  [[ -n "$cg" ]] || return 1
  for f in "/sys/fs/cgroup$cg" "/sys/fs/cgroup/unified$cg" "/sys/fs/cgroup/systemd$cg"; do
    if [[ -r "$f/cgroup.procs" ]]; then procs=" $(tr '\n' ' ' < "$f/cgroup.procs") "; break; fi
  done
  [[ -n "$procs" ]] || return 1
  for pid in $(ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2); do
    [[ "$procs" == *" $pid "* ]] && return 0
  done
  return 1
}

# Another program on the port would get the agent's requests with the key.
tabularis_fail_if_taken() {  # <port>: stops the start if something else listens on it
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 0
  tabularis_listening "$1" && return 0
  echo "error: TABULARIS_PORT $1 on 127.0.0.1 is in use by another program; set another port (README, Tabularis (MCP))" >&2
  exit 1
}
