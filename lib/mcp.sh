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
#                        the sidecars ab-mcp-<name> or ab-mcp-<name>-<part>
#                        (<name> the module's): run.sh removes such
#                        containers that no enabled module started, except
#                        a skipped module's (mcp_skip). A program that must
#                        run on the host goes through start_host_unit
#                        (lib/sidecars.sh), named agentbox-mcp-<name>[-*]. It runs
#                        in a subshell: on an error it says why with
#                        ab_error (the reason the warning gives) and exits
#                        non-zero, and that module alone is left out
#                        of the start (mcp_skip); exit "$MCP_TAKE_AWAY" if
#                        what it runs must go too (access taken away).
#                        Sidecars, copies and host services it starts are
#                        marked as its own (agentbox.module) and found by
#                        that mark. Variables it sets
#                        do not come back, only the sidecars and host
#                        services it asked for.
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

# A module that cannot run is left out of this start, with a warning: the
# session starts without it rather than not at all. With "keep" (sidecars
# and host services only: its MCP_EGRESS hosts leave squid), what it
# already runs (marked with its name, lib/sidecars.sh) stays for the sessions using it: the cleanups skip MCP_SKIPPED. That is
# for a start that failed. A setting or secret that is gone says access
# should go, and so does an mcp_start that exits $MCP_TAKE_AWAY (mcp/dbhub,
# mcp/woodpecker, mcp/tabularis): then its sidecars, their copies in the
# cache and its host services are removed like a disabled module's.
# The status of an mcp_start that wants its module's access taken away.
# Not 1-3, which common tools use (systemctl is-active returns 3).
MCP_TAKE_AWAY=97
MCP_SKIPPED=()
mcp_skip() {  # <name> <why> [keep]
  local n kept=()
  [[ "${3:-}" == keep ]] && MCP_SKIPPED+=("$1")
  ab_warn "MCP module '$1' left out of this session: $2"
  for n in "${MCP_ENABLED[@]}"; do [[ "$n" == "$1" ]] || kept+=("$n"); done
  MCP_ENABLED=("${kept[@]}")
}

# Required settings and secrets of every enabled module; a module without
# them is skipped (mcp_skip). Caller tokens are created when missing. Also
# collects images, session arguments, NO_PROXY hosts, remote hosts and the
# registrations to clean up.
mcp_check_secrets() {
  local name key s missing
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load "$name"
    for key in ${MCP_REQUIRED_CONFIG[@]+"${MCP_REQUIRED_CONFIG[@]}"}; do
      if [[ -z "${!key:-}" ]]; then
        mcp_skip "$name" "it needs $key in $CONFIG_FILE (agentbox setup)"
        continue 2
      fi
    done
    missing=()
    for s in ${MCP_SECRETS[@]+"${MCP_SECRETS[@]}"}; do
      secret_exists "$s" || missing+=("$s")
    done
    if (( ${#missing[@]} )); then
      mcp_skip "$name" "missing podman secrets ${missing[*]} (agentbox setup, or README, Setup in detail, step 5)"
    fi
  done
  mcp_collect
}

# Images, session arguments, NO_PROXY hosts, remote hosts and registrations
# of the enabled modules; caller tokens are created when missing.
mcp_collect() {
  local name host var h
  MCP_IMAGES_ALL=()
  MCP_SESSION_ARGS=()
  MCP_NO_PROXY=()
  MCP_EGRESS_ALL=()
  MCP_MANAGED=""
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load "$name"
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

# Each module's mcp_start runs in a subshell, so that its exit (a bad
# setting, a sidecar that fails) stops that module alone: it is skipped
# (mcp_skip). What a module that succeeded asked for comes back on fd 3.
# Then the lists of mcp_collect are made again, without the skipped.
mcp_start_all() {
  local name rc res kind item skipped="" why d c u
  local errf="${AB_WARNINGS_FILE:+$AB_WARNINGS_FILE.err}"
  [[ -n "$errf" ]] || errf="$(mktemp)"
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load "$name"
    declare -F mcp_start >/dev/null || continue
    # The lists come back on the subshell's fd 3, its output goes to stderr:
    # no file, so starts at the same time cannot mix them up.
    : > "$errf"
    set +e
    res="$(
      (
        set -e
        SIDECARS_WANTED=(); HOST_UNITS_WANTED=()
        AB_MODULE_ERRORS="$errf"
        AB_CURRENT_MODULE="$name"
        # Without fd 3: a program it starts that stays (conmon, podman's
        # pause process) would hold the capture open and the start with it.
        mcp_start 3>&-
        printf 's %s\n' ${SIDECARS_WANTED[@]+"${SIDECARS_WANTED[@]}"} >&3
        printf 'h %s\n' ${HOST_UNITS_WANTED[@]+"${HOST_UNITS_WANTED[@]}"} >&3
      ) 3>&1 >&2
    )"
    rc=$?
    set -e
    # The reason: what the module reported with ab_error (its output went to
    # the terminal as it came). A command that failed on its own (podman,
    # under set -e) reported nothing here: the output above says.
    why="$(awk 'NR <= 3' "$errf" | paste -sd ';' -)" || why=""
    why="${why:-its start failed, see the output above}"
    if (( rc == MCP_TAKE_AWAY )); then
      mcp_skip "$name" "$why; what it ran is removed"
      # Now, not at the cleanup at the end of the start: a later step that
      # fails would leave them serving.
      module_remove "$name"
      skipped=1; continue
    elif (( rc != 0 )); then
      mcp_skip "$name" "$why; open sessions keep what it already runs" keep
      skipped=1; continue
    fi
    while read -r kind item; do
      [[ -n "$item" ]] || continue
      if [[ "$kind" == s ]]; then SIDECARS_WANTED+=("$item"); else HOST_UNITS_WANTED+=("$item"); fi
    done <<<"$res"
  done
  rm -f -- "$errf"
  [[ -z "$skipped" ]] || mcp_collect
}
