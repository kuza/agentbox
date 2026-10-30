# MCP servers as modules: mcp/<name>/mcp.sh (shared, in git) or
# <AB_HOME>/mcp.local/<name>/mcp.sh (yours; wins over mcp/). AB_MCP in
# config.env lists the enabled ones; context7 is always enabled.
#
# A module is a bash file, sourced by run.sh on the host, so it is code with
# the same trust as run.sh: read a module before you enable it. It sets:
#
#   MCP_URL              URL the agents connect to (required)
#   MCP_DESCRIPTION      one line, shown by pi
#   MCP_CONFIG=()        config.env keys the module reads
#   MCP_REQUIRED_CONFIG=()  of those, the ones that must be set
#   MCP_SECRETS=()       podman secrets that must exist (README, Setup in detail, step 5)
#   MCP_SECRET_HELP=()   "<secret>: what to type for it", for agentbox setup
#   mcp_secret_value()   optional: <secret> <what was typed> -> the secret's
#                        value, when it is not stored as typed (graylog)
#   MCP_OWN_SECRETS=()   podman secrets mcp_start creates itself; agentbox
#                        uninstall --all removes them
#   MCP_CALLER_SECRET    a caller token secret, generated on first use. The
#                        agents send it as "Authorization: Bearer <token>";
#                        the sidecar checks it. Inside the session it is the
#                        environment variable AB_MCP_TOKEN_<NAME>.
#   MCP_EGRESS=()        hosts the agent reaches directly (remote servers),
#                        added to squid's allowlist (lib/egress.sh)
#   MCP_IMAGES=()        images AB_UPGRADE pulls, on one line: agentbox
#                        uninstall reads them as text, literal or "$VAR"
#                        with a VAR="..." line of the module's own
#   mcp_start()          starts the module's sidecars with start_sidecar, if
#                        it has any. MCP_DIR is the module's directory. Mount
#                        its files through sidecar_copy, never directly. Name
#                        the sidecars ab-mcp-*: run.sh removes such containers
#                        that no enabled module started. A program that must
#                        run on the host goes through start_host_unit
#                        (lib/sidecars.sh), named agentbox-mcp-*.
#
# Sourced by run.sh. Provides mcp_init, mcp_check_secrets, mcp_write_configs,
# mcp_start_all and these results: MCP_ENABLED, MCP_CONFIG_KEYS, MCP_IMAGES_ALL,
# MCP_SESSION_ARGS, MCP_NO_PROXY, MCP_CLAUDE_JSON, MCP_PI_JSON, MCP_EGRESS_ALL
# ("host module" per entry, for lib/egress.sh), MCP_MANAGED (name and URL per
# line, for cleaning up old registrations).

MCP_DIRS=("$USER_MCP_DIR" "$SCRIPT_DIR/mcp")

mcp_load() {  # <name>: source the module, resetting the MCP_* variables first
  local d
  unset -f mcp_start mcp_secret_value
  MCP_URL=""; MCP_DESCRIPTION=""; MCP_CALLER_SECRET=""
  MCP_CONFIG=(); MCP_REQUIRED_CONFIG=(); MCP_SECRETS=(); MCP_SECRET_HELP=(); MCP_OWN_SECRETS=(); MCP_EGRESS=(); MCP_IMAGES=()
  MCP_DIR=""
  for d in "${MCP_DIRS[@]}"; do
    if [[ -f "$d/$1/mcp.sh" ]]; then MCP_DIR="$d/$1"; break; fi
  done
  if [[ -z "$MCP_DIR" ]]; then
    echo "error: AB_MCP: no MCP module '$1' (looked for $USER_MCP_DIR/$1/mcp.sh and mcp/$1/mcp.sh)" >&2
    exit 2
  fi
  # shellcheck source=/dev/null
  source "$MCP_DIR/mcp.sh"
  if [[ -z "$MCP_URL" ]]; then
    echo "error: $MCP_DIR/mcp.sh does not set MCP_URL" >&2
    exit 2
  fi
}

mcp_token_var() {  # <name>: environment variable of the caller token
  local v="${1^^}"
  echo "AB_MCP_TOKEN_${v//-/_}"
}

# Enabled modules from AB_MCP, and the config keys they read. Run after the
# first config pass (AB_MCP may come from config.env), before the second.
mcp_init() {
  local name seen=" " list="${AB_MCP:-}"
  MCP_ENABLED=()
  MCP_CONFIG_KEYS=()
  for name in context7 ${list//,/ }; do
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "error: AB_MCP: invalid module name '$name'" >&2
      exit 2
    fi
    [[ "$seen" == *" $name "* ]] && continue
    seen+="$name "
    MCP_ENABLED+=("$name")
    mcp_load "$name"
    MCP_CONFIG_KEYS+=(${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"})
  done
}

# Required settings and secrets of every enabled module; caller tokens are
# created when missing. Also collects images, session arguments, NO_PROXY
# hosts, remote hosts and the registrations to clean up.
mcp_check_secrets() {
  local name key s missing=() host var h
  MCP_IMAGES_ALL=()
  MCP_SESSION_ARGS=()
  MCP_NO_PROXY=()
  MCP_EGRESS_ALL=()
  MCP_MANAGED=""
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load "$name"
    for key in ${MCP_REQUIRED_CONFIG[@]+"${MCP_REQUIRED_CONFIG[@]}"}; do
      if [[ -z "${!key:-}" ]]; then
        echo "error: MCP module '$name' needs $key in $CONFIG_FILE" >&2
        exit 2
      fi
    done
    for s in ${MCP_SECRETS[@]+"${MCP_SECRETS[@]}"}; do
      podman secret inspect "$s" >/dev/null 2>&1 || missing+=("$s ($name)")
    done
    if [[ -n "$MCP_CALLER_SECRET" ]]; then
      ensure_caller_secret "$MCP_CALLER_SECRET"
      var="$(mcp_token_var "$name")"
      MCP_SESSION_ARGS+=(--secret "$MCP_CALLER_SECRET,type=env,target=$var")
    fi
    MCP_IMAGES_ALL+=(${MCP_IMAGES[@]+"${MCP_IMAGES[@]}"})
    for h in ${MCP_EGRESS[@]+"${MCP_EGRESS[@]}"}; do MCP_EGRESS_ALL+=("$h $name"); done
    # Sidecars are reached by container name, without the proxy.
    host="${MCP_URL#*://}"; host="${host%%[:/]*}"
    [[ "$host" != *.* ]] && MCP_NO_PROXY+=("$host")
    MCP_MANAGED+="$name $MCP_URL"$'\n'
  done
  if (( ${#missing[@]} )); then
    echo "error: missing podman secrets for MCP modules: ${missing[*]} (README, Setup in detail, step 5)" >&2
    exit 1
  fi
}

json_str() {  # <text>: JSON string literal
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Writes the MCP config for Claude Code (--mcp-config) and pi
# (~/.pi/agent/mcp.json) into <cache>/agentbox. Each file is written anew and renamed, so a
# running session keeps the version it mounted. Tokens stay as ${VAR}: the
# agents expand them from the environment.
mcp_write_configs() {
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox" name hdr sep_c="" sep_p=""
  local claude="" pi=""
  mkdir -p "$dir"
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load "$name"
    hdr=""
    if [[ -n "$MCP_CALLER_SECRET" ]]; then
      hdr=", \"headers\": { \"Authorization\": \"Bearer \${$(mcp_token_var "$name")}\" }"
    fi
    claude+="$sep_c    $(json_str "$name"): { \"type\": \"http\", \"url\": $(json_str "$MCP_URL")$hdr }"
    pi+="$sep_p    $(json_str "$name"): { \"url\": $(json_str "$MCP_URL")$hdr, \"description\": $(json_str "$MCP_DESCRIPTION") }"
    sep_c=$',\n'; sep_p=$',\n'
  done
  MCP_CLAUDE_JSON="$dir/mcp-claude.json"
  MCP_PI_JSON="$dir/mcp-pi.json"
  write_file "$MCP_CLAUDE_JSON" "{"$'\n'"  \"mcpServers\": {"$'\n'"$claude"$'\n'"  }"$'\n'"}"$'\n'
  write_file "$MCP_PI_JSON" "{"$'\n'"  \"mcpServers\": {"$'\n'"$pi"$'\n'"  }"$'\n'"}"$'\n'
}

write_file() {  # <path> <content>: replace atomically (new inode)
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  printf '%s' "$2" > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$1"
}

mcp_start_all() {
  local name
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load "$name"
    if declare -F mcp_start >/dev/null; then
      mcp_start
    fi
  done
}
