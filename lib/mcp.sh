# MCP servers as modules: mcp/<name>/mcp.sh (shared, in git) or
# <AB_HOME>/mcp.local/<name>/mcp.sh (yours; wins over mcp/). AB_MCP in
# config.toml lists the enabled ones; context7 is always enabled.
#
# A module with module.toml (a manifest) describes itself as data:
# mcp_load_manifest reads it, and runs no code of the module. mcp_bind
# runs its mcp.sh, if it has one. The text below is about the old format,
# a module with only mcp.sh.
#
# A module is a bash file, sourced by run.sh on the host, so it is code with
# the same trust as run.sh: read a module before you enable it. It sets:
#
#   MCP_URL              URL the agents connect to (required)
#   MCP_DESCRIPTION      one line, shown by pi
#   MCP_SERVERS=()       optional, for a module with more than one server:
#                        "<name>|<url>|<caller or ->|<description>" each, in
#                        place of the one server <module name>, MCP_URL. With
#                        "caller" the agents send the module's caller token
#                        to that one; with "-" nothing (a remote server).
#   MCP_CONFIG=()        config.toml keys the module reads
#   MCP_REQUIRED_CONFIG=()  of those, the ones that must be set
#   MCP_SECRETS=()       podman secrets that must exist (README, Setup in detail, step 5)
#   MCP_SECRET_HELP=()   "<secret>: what to type for it", for agentbox setup
#   mcp_secret_value()   optional: <secret> <what was typed> -> the secret's
#                        value, when it is not stored as typed (graylog)
#   MCP_SECRETS_BY_SETTING=()  optional, one line, one entry: "<KEY> <prefix>" for
#                        secrets named <prefix><value> for each value of
#                        setting KEY (github: "GH_OWNERS github_pat_");
#                        agentbox uninstall --all removes those, read from
#                        config.toml
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
#                        with a VAR=... line of the module's own (quoted
#                        or not, indented or not)
#   mcp_check()          optional: checks the module's settings once they
#                        are read; prints what is wrong, one line each, and
#                        nothing when they are fine. It must not start or
#                        change anything: agentbox setup runs it too. A
#                        problem leaves the module out of the start, and
#                        what it runs goes (as for an emptied setting).
#                        Keep MCP_CONFIG=(...) on one line: for a module
#                        that is not enabled or does not parse, mcp_init
#                        reads it as text.
#                        Code outside the functions runs without set -e.
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

mcp_find() {  # <name>: prints the module's directory; 1 if there is none
  local d
  for d in "${MCP_DIRS[@]}"; do
    if [[ -f "$d/$1/module.toml" || -f "$d/$1/mcp.sh" ]]; then printf '%s\n' "$d/$1"; return 0; fi
  done
  return 1
}

# Each module once, yours first: a directory with a module.toml or an mcp.sh.
mcp_names() {
  local d f name
  local -A found=()
  for d in "${MCP_DIRS[@]}"; do
    for f in "$d"/*/; do
      name="${f%/}"; name="${name##*/}"
      [[ ( -f "$f/module.toml" || -f "$f/mcp.sh" ) && -z "${found[$name]+x}" ]] || continue
      found[$name]=1
      printf '%s\n' "$name"
    done
  done
}

# 0 if the mcp.sh in <directory> parses (bash -n).
mcp_parses() {  # <name> <its directory, from mcp_find>
  bash -n "$2/mcp.sh" 2>/dev/null
}

# Loads again a module that mcp_check_secrets let through (status 0). A
# module that changed during the start stops the start, as before.
mcp_load_again() {  # <name>
  mcp_load "$1" && return 0
  echo "error: MCP module '$1': $MCP_PROBLEM" >&2
  exit 2
}

# Reads module <name> into the MCP_* variables, reset first. It never
# exits. Status: 0 usable, 1 a setting fails or is missing (MCP_MISSING),
# 2 broken, 3 no Python, 4 no such module. MCP_PROBLEM gives the reason.
# With --declared, it checks no setting values (status 0, 2, 3 or 4).
# A module with module.toml goes to mcp_load_manifest, which runs no module
# code (MCP_FORMAT=manifest). A module with only mcp.sh (MCP_FORMAT=old)
# gives 0, 1, 2 or 4: mcp_load sources its mcp.sh, also with --declared.
# MCP_SERVERS has the servers: the old adapter fills it also with
# --declared, the manifest adapter only without --declared (with
# MCP_EGRESS). MCP_SECRET_HELP_OF[<secret>] holds the help of each secret.
mcp_load() {  # <name> [--declared]
  local h
  unset -f mcp_start mcp_secret_value mcp_check
  MCP_PROBLEM=""; MCP_ONE_SERVER=""; MCP_FORMAT=""; MCP_MISSING=()
  MCP_URL=""; MCP_DESCRIPTION=""; MCP_CALLER_SECRET=""; MCP_SERVERS=(); MCP_SECRETS_BY_SETTING=()
  MCP_CONFIG=(); MCP_REQUIRED_CONFIG=(); MCP_SECRETS=(); MCP_SECRET_HELP=(); MCP_OWN_SECRETS=(); MCP_EGRESS=(); MCP_IMAGES=()
  declare -gA MCP_SECRET_HELP_OF=() MCP_SETTING_HELP=() MCP_IMAGE=() MCP_SECRET=() MCP_VALUE=() MCP_FIELD=() MCP_ITEMS=()
  if ! MCP_DIR="$(mcp_find "$1")"; then
    MCP_PROBLEM="this agentbox has no such module (looked for module.toml or mcp.sh in $USER_MCP_DIR/$1 and mcp/$1)"
    return 4
  fi
  if [[ -f "$MCP_DIR/module.toml" ]]; then
    mcp_load_manifest "$1" "${2:-}"
    return
  fi
  MCP_FORMAT=old
  if ! mcp_parses "$1" "$MCP_DIR"; then
    MCP_PROBLEM="its mcp.sh does not parse (bash -n $MCP_DIR/mcp.sh)"
    return 2
  fi
  # Its last line's status does not count: a false "[[ ... ]] && ..." there
  # would end the start under set -e. "|| true" turns set -e off for the
  # whole file (README, Writing a module).
  # shellcheck source=/dev/null
  source "$MCP_DIR/mcp.sh" || true
  # A module without MCP_SERVERS has one server: <name> at MCP_URL.
  # mcp_servers_problem checks that MCP_URL.
  if (( ! ${#MCP_SERVERS[@]} )); then
    MCP_ONE_SERVER=1
    MCP_SERVERS=("$1|$MCP_URL|${MCP_CALLER_SECRET:+caller}|$MCP_DESCRIPTION")
  fi
  for h in ${MCP_SECRET_HELP[@]+"${MCP_SECRET_HELP[@]}"}; do
    # The first line of a secret wins, as in setup_secret_help.
    [[ "$h" == ?*": "* && -z "${MCP_SECRET_HELP_OF[${h%%: *}]+x}" ]] && MCP_SECRET_HELP_OF[${h%%: *}]="${h#*: }"
  done
  [[ "${2:-}" == --declared ]] || mcp_missing
}

# The variables of the old format. mcp_load resets them. mcp_bind refuses
# them in the mcp.sh of a manifest module: one file holds the data.
MCP_OLD_VARS=(MCP_URL MCP_DESCRIPTION MCP_CALLER_SECRET MCP_SERVERS MCP_SECRETS_BY_SETTING MCP_CONFIG
  MCP_REQUIRED_CONFIG MCP_SECRETS MCP_SECRET_HELP MCP_OWN_SECRETS MCP_EGRESS MCP_IMAGES)

# Runs the code of the manifest module that mcp_load loaded with status 0
# or 1. It sets the settings as variables and sources the mcp.sh. With
# --check, it also runs mcp_check: give --check only after status 0.
# Status 0: usable, also for a module with no mcp.sh. Status 1: mcp_check
# found a problem. Status 2: the mcp.sh is broken, stops at its top level
# (exit, or an unset variable), or sets an old MCP_* variable. For 1 and 2,
# the reason goes to stdout. Other output of the module code goes to
# stderr. Run it in a subshell: what it sets stays there.
mcp_bind() {  # <name> [--check]
  # Names that the top level of mcp.sh does not use: it sees these locals.
  local _mcp_k _mcp_why _mcp_old
  [[ -f "$MCP_DIR/mcp.sh" ]] || return 0
  if ! mcp_parses "$1" "$MCP_DIR"; then
    echo "its mcp.sh does not parse (bash -n $MCP_DIR/mcp.sh)"
    return 2
  fi
  for _mcp_k in ${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"}; do printf -v "$_mcp_k" '%s' "${MCP_VALUE[$_mcp_k]-}"; done
  # A "declare -g" in mcp.sh goes past the locals of mcp_bind_source.
  _mcp_old="$(declare -p "${MCP_OLD_VARS[@]}" 2>/dev/null)" || true
  mcp_bind_source || return 2
  if [[ "$(declare -p "${MCP_OLD_VARS[@]}" 2>/dev/null)" != "$_mcp_old" ]]; then
    echo "$MCP_DIR/mcp.sh sets a variable of the old format with declare -g. The module has a module.toml: keep one of the two"
    return 2
  fi
  [[ "${2:-}" == --check ]] && declare -F mcp_check >/dev/null || return 0
  # Its status does not count, only what it prints.
  _mcp_why="$(mcp_check || true)"
  [[ -z "$_mcp_why" ]] || { printf '%s\n' "$_mcp_why"; return 1; }
}

# Sources the mcp.sh for mcp_bind. Locals hide the old MCP_* variables of
# mcp_load, so the check sees only what mcp.sh sets. The return of this
# function makes the normalized variables of mcp_load visible again.
mcp_bind_source() {
  local "${MCP_OLD_VARS[@]}" _mcp_var _mcp_out
  # An exit at the top level of mcp.sh, also "exit 0", is a broken module.
  # The trap writes the reason to the stdout of mcp_bind: an exit keeps the
  # redirection of the source to stderr.
  exec {_mcp_out}>&1
  trap 'echo "$MCP_DIR/mcp.sh stops at its top level with status $?: keep exit in its functions" >&'"$_mcp_out"'; trap - EXIT; exit 2' EXIT
  # Code outside the functions runs without set -e, as in mcp_load.
  # shellcheck source=/dev/null
  source "$MCP_DIR/mcp.sh" >&2 || true
  trap - EXIT
  exec {_mcp_out}>&-
  [[ "$(declare -p "${MCP_OLD_VARS[@]}" 2>/dev/null)" == *=* ]] || return 0
  for _mcp_var in "${MCP_OLD_VARS[@]}"; do
    if [[ "$(declare -p "$_mcp_var" 2>/dev/null)" == *=* ]]; then
      echo "$MCP_DIR/mcp.sh sets $_mcp_var of the old format. The module has a module.toml: keep one of the two"
      return 2
    fi
  done
}

# Runs mcp_bind --check in a subshell. The reason goes to stdout, the status
# is 0, 1 or 2 as for mcp_bind. Without a reason, a stop is status 2.
mcp_bind_check() {  # <name>
  local why rc=0
  why="$(mcp_bind "$1" --check)" || rc=$?
  (( ! rc )) || [[ -n "$why" ]] || { why="its mcp.sh stopped with status $rc"; rc=2; }
  [[ -z "$why" ]] || printf '%s\n' "$why"
  return $(( rc > 2 ? 2 : rc ))
}

# The required settings that are not set, into MCP_MISSING. 1 if there
# are any, with the first one in MCP_PROBLEM. An empty value counts as not
# set. A manifest module has its values (after the defaults) in MCP_VALUE.
mcp_missing() {
  local key
  for key in ${MCP_REQUIRED_CONFIG[@]+"${MCP_REQUIRED_CONFIG[@]}"}; do
    [[ -n "${MCP_VALUE[$key]-${!key:-}}" ]] || MCP_MISSING+=("$key")
  done
  (( ${#MCP_MISSING[@]} )) || return 0
  MCP_PROBLEM="it needs ${MCP_MISSING[0]} in $CONFIG_FILE (agentbox setup)"
  return 1
}

# "<file>:<line>" of the key <path> for mcp_load_manifest (its f and l).
# A key with no line (in an inline table, or a table with no keys) gives
# "<file>" only; the message gives the path.
mcp_manifest_at() {  # <path>
  local at="${l[$1]:-0}"
  at="${at%% *}"
  if (( at )); then echo "$f:$at"; else echo "$f"; fi
}

# The manifest adapter of mcp_load: reads $MCP_DIR/module.toml and runs no
# module code. A broken manifest gives status 2, and MCP_PROBLEM is
# "<file>:<line>: <reason> (<code>)" (tests/manifest/README lists the
# codes). Without --declared, also the resolved part: MCP_VALUE (the
# setting values after the defaults), MCP_SERVERS and MCP_EGRESS.
mcp_load_manifest() {  # <name> [--declared]
  local f="$MCP_DIR/module.toml" rc=0 k i n name desc auth at names=" "
  local -A v=() l=()
  MCP_FORMAT=manifest
  toml_load manifest "$f" v l 2>/dev/null || rc=$?
  if (( rc == 3 )); then
    MCP_PROBLEM="agentbox needs Python 3.11 or newer to read $f"
    return 3
  elif (( rc )); then
    # Read again for the message, the first error only. A failed read is
    # not in the cache, and $(...) loses the values (they are not needed).
    MCP_PROBLEM="$(toml_load manifest "$f" v 2>&1 >/dev/null | head -1)" || true
    return 2
  fi
  # The reader accepts 0 and lower; the first format is 1.
  if (( v[format] < 1 )); then
    MCP_PROBLEM="$(mcp_manifest_at format): format: ${v[format]} is not a format; the first format is 1 (bad-format)"
    return 2
  fi
  # Its secrets would get the prefix git_ of the modules from git.
  if [[ "$1" == git ]]; then
    MCP_PROBLEM="$f: the name 'git' is for the modules from git: give the module another name (reserved-name)"
    return 2
  fi
  MCP_DESCRIPTION="${v[description]:-}"
  read -ra MCP_CONFIG <<<"${v[settings]:-}"
  for k in ${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"}; do
    [[ "${v[settings.$k.required]:-}" != 1 ]] || MCP_REQUIRED_CONFIG+=("$k")
    [[ -z "${v[settings.$k.help]:-}" ]] || MCP_SETTING_HELP[$k]="${v[settings.$k.help]}"
  done
  for k in ${v[secrets]:-}; do
    if [[ "$k" == mcp_caller ]]; then
      # The line of its header: from a key in it, or from the name record
      # (the line of the first table of secrets).
      at=secrets.mcp_caller.help
      [[ "${v[secrets]%% *}" != mcp_caller ]] || at=secrets
      [[ -n "${l[$at]+x}" ]] || at=secrets.mcp_caller.for_each
      MCP_PROBLEM="$(mcp_manifest_at "$at"): secrets.mcp_caller: agentbox makes this secret for a server with caller = true; remove it (reserved-secret)"
      return 2
    fi
    # shortcut: a for_each secret is left out; ticket 06 adds its names.
    [[ -z "${v[secrets.$k.for_each]+x}" ]] || continue
    MCP_SECRET[$k]="$1_$k"
    MCP_SECRETS+=("$1_$k")
    [[ -z "${v[secrets.$k.help]:-}" ]] || MCP_SECRET_HELP_OF[$1_$k]="${v[secrets.$k.help]}"
  done
  for k in ${v[own_secrets]:-}; do
    MCP_SECRET[$k]="$1_$k"
    MCP_OWN_SECRETS+=("$1_$k")
  done
  for k in ${v[images]:-}; do
    MCP_IMAGE[$k]="${v[images.$k]}"
    MCP_IMAGES+=("${v[images.$k]}")
  done
  n="${v[servers.#]:-0}"
  if (( ! n )); then
    MCP_PROBLEM="$(mcp_manifest_at format): servers: a module needs at least one [[servers]] (no-server)"
    return 2
  fi
  for (( i = 0; i < n; i++ )); do
    [[ "${v[servers.$i.caller]:-}" != 1 ]] || MCP_CALLER_SECRET="$1_mcp_caller"
  done
  [[ -z "$MCP_CALLER_SECRET" ]] || MCP_SECRET[mcp_caller]="$MCP_CALLER_SECRET"
  [[ "${2:-}" != --declared ]] || return 0
  for k in ${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"}; do
    MCP_VALUE[$k]="${!k:-}"
    [[ -n "${MCP_VALUE[$k]}" ]] || MCP_VALUE[$k]="${v[settings.$k.default]:-}"
  done
  for (( i = 0; i < n; i++ )); do
    name="${v[servers.$i.name]}"
    if [[ ! "$name" =~ $AB_NAME_RE ]]; then
      MCP_PROBLEM="$(mcp_manifest_at "servers.$i.name"): servers.$i.name: '$name' is not a server name: use lowercase letters, digits and - (bad-server-name)"
      return 2
    fi
    if [[ "$names" == *" $name "* ]]; then
      MCP_PROBLEM="$(mcp_manifest_at "servers.$i.name"): servers.$i.name: the server '$name' is in the manifest two times (duplicate-server)"
      return 2
    fi
    names+="$name "
    desc="servers.$i.description"
    [[ -n "${v[$desc]+x}" ]] || desc=description
    # The name check above refuses a | in a name.
    for k in "servers.$i.url" "$desc"; do
      [[ "${v[$k]:-}" == *"|"* ]] || continue
      MCP_PROBLEM="$(mcp_manifest_at "$k"): $k: a server cannot have a | in its URL or description (pipe-in-server)"
      return 2
    done
    auth=-
    [[ "${v[servers.$i.caller]:-}" != 1 ]] || auth=caller
    MCP_SERVERS+=("$name|${v[servers.$i.url]}|$auth|${v[$desc]:-}")
  done
  read -ra MCP_EGRESS <<<"${v[egress]:-}"
  mcp_missing
}

# The servers of the module mcp_load loaded, "<name>|<url>|<caller or
# ->|<description>" per line.
mcp_servers() {
  (( ${#MCP_SERVERS[@]} )) || return 0
  printf '%s\n' "${MCP_SERVERS[@]}"
}

# What is wrong with the servers of the module mcp_load loaded, on stdout;
# nothing if they are fine. Names already taken by other modules are in
# <taken> (" server=module ..."). Run after the settings are read: a URL may
# come from them. Status 3 for a missing URL ("take away"), 0 for the rest
# ("keep"; see mcp_check_secrets).
mcp_servers_problem() {  # <module name> <taken>
  local server url auth names=" " owner
  if [[ -n "$MCP_ONE_SERVER" && -z "$MCP_URL" ]]; then
    echo "no URL: its mcp.sh sets no MCP_URL, or the setting it comes from is empty"; return 3
  fi
  if [[ -n "$MCP_ONE_SERVER" && "$MCP_URL" == *"|"* ]]; then
    echo "its MCP_URL has a |"; return
  fi
  while IFS='|' read -r server url auth _; do
    if [[ "$server" =~ $AB_NAME_RE && -z "$url" ]]; then
      echo "no URL for its server '$server': the setting it comes from is empty"; return 3
    fi
    if [[ ! "$server" =~ $AB_NAME_RE || -z "$url" || ( "$auth" != caller && "$auth" != - && -n "$auth" ) ]]; then
      echo "a server in its mcp.sh must be \"<name>|<url>|<caller or ->|<description>\", got '$server|$url|$auth'"; return
    fi
    # Without the secret the agents would send no token, and every call
    # would get 401 from the module's nginx.
    if [[ "$auth" == caller && -z "$MCP_CALLER_SECRET" ]]; then
      echo "its server '$server' is marked caller, but its mcp.sh sets no MCP_CALLER_SECRET"; return
    fi
    # Two servers of one name: the agents' config would keep one of them.
    if [[ "$names" == *" $server "* ]]; then
      echo "its MCP_SERVERS has the server '$server' twice"; return
    fi
    if [[ "$2" == *" $server="* ]]; then
      owner="${2#* "$server"=}"; owner="${owner%% *}"
      echo "its server '$server' has the name of one of module '$owner'"; return
    fi
    names+="$server "
  done < <(mcp_servers)
}

mcp_egress_has() {  # <host>: 0 if the loaded module's MCP_EGRESS lists it
  local h
  for h in ${MCP_EGRESS[@]+"${MCP_EGRESS[@]}"}; do [[ "${h%:*}" == "$1" ]] && return 0; done
  return 1
}

mcp_token_var() {  # <name>: environment variable of the caller token
  local v="${1^^}"
  echo "AB_MCP_TOKEN_${v//-/_}"
}

# The keys of the MCP_CONFIG=(...) line of <mcp.sh>, read as text: for a
# module that is not loaded (disabled, or one that does not parse).
mcp_config_keys_text() {  # <mcp.sh>
  sed -n 's/^MCP_CONFIG=(\([A-Za-z0-9_ ]*\))[[:space:]]*$/\1/p' "$1" | tr '\n' ' '
}

# Enabled modules from AB_MCP, and the config keys they read. Run after the
# first config pass (AB_MCP may come from config.toml), before the second.
mcp_init() {
  local name keys rc d seen=" " list="${AB_MCP:-}"
  MCP_ENABLED=()
  MCP_CONFIG_KEYS=()
  for name in context7 ${list//,/ }; do
    if [[ ! "$name" =~ $AB_NAME_RE ]]; then
      echo "error: AB_MCP: invalid module name '$name'" >&2
      exit 2
    fi
    [[ "$seen" == *" $name "* ]] && continue
    seen+="$name "
    # A module this version does not have (a newer or older one's, or a
    # typo): left out, with a warning, like a module that cannot run.
    # What it runs (another version's sessions) stays.
    rc=0; mcp_load "$name" --declared || rc=$?
    case "$rc" in
      0) ;;
      4) ab_warn "MCP module '$name' left out of this session: $MCP_PROBLEM. Sidecars of it that run stay;" \
                 "take it out of AB_MCP to have them removed"
         MCP_UNKNOWN+=("$name")
         continue ;;
      3) toml_no_python "read $MCP_DIR/module.toml"; exit 2 ;;
      *) ab_warn "MCP module '$name' left out of this session: $MCP_PROBLEM"
         # Its settings are not read; they get no warning (MCP_QUIET_KEYS).
         MCP_SKIPPED+=("$name")
         continue ;;
    esac
    MCP_ENABLED+=("$name")
    MCP_CONFIG_KEYS+=(${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"})
    # A shared module does not warn: the shared modules change one by one.
    if [[ "$MCP_FORMAT" == old && "$MCP_DIR" == "$USER_MCP_DIR/"* ]]; then
      ab_warn "MCP module '$name' has the old format (only mcp.sh). v0.3.0 removes this format:" \
              "convert the module to module.toml (README, \"Converting a module\")"
    fi
  done
  # The settings of each module that this version has (bb4 configured,
  # then removed from AB_MCP): config.toml may keep them, and the second
  # pass ignores them without a warning. Each name once, as mcp_find finds
  # it: a module of yours replaces the shared one of that name. A key that
  # no module has still warns. The keys come from the [settings] of a
  # manifest (none when it cannot be read), and from the mcp.sh of a module
  # of the old format as text: it is not sourced.
  MCP_QUIET_KEYS=()
  while IFS= read -r name; do
    [[ "$name" =~ $AB_NAME_RE ]] || continue
    d="$(mcp_find "$name")" || continue
    if [[ -f "$d/module.toml" ]]; then
      keys=()
      if mcp_load "$name" --declared; then keys=(${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"}); fi
    else
      read -ra keys <<<"$(mcp_config_keys_text "$d/mcp.sh")"
    fi
    MCP_QUIET_KEYS+=(${keys[@]+"${keys[@]}"})
  done < <(mcp_names)
}

# A module that cannot run is left out of this start, with a warning: the
# session starts without it rather than not at all. With "keep" (sidecars
# and host services only: its MCP_EGRESS hosts leave squid), what it
# already runs (marked with its name, lib/sidecars.sh) stays for the
# sessions using it: the cleanups skip MCP_SKIPPED. That is for a start that
# failed. Access goes for a setting or secret that is gone, a setting that
# mcp_check refuses (check settings there, not in mcp_start), no URL, and an
# mcp_start that exits $MCP_TAKE_AWAY (mcp/dbhub, mcp/woodpecker): then
# mcp_skip removes its sidecars, their copies in the cache and its host
# services at once, like a disabled module's.
# The status of an mcp_start that wants its module's access taken away.
# Not 1-3, which common tools use (systemctl is-active returns 3).
MCP_TAKE_AWAY=97
MCP_SKIPPED=()
# Modules this version does not have: what of theirs carries their mark
# stays, nothing by name alone (a typo "git" would keep ab-mcp-git-lab).
MCP_UNKNOWN=()
mcp_skip() {  # <name> <why> [keep]
  local n kept=()
  ab_warn "MCP module '$1' left out of this session: $2"
  # Without "keep", what it runs goes now, not at the cleanup at the end of
  # the start: a later step that fails would leave it serving.
  if [[ "${3:-}" == keep ]]; then MCP_SKIPPED+=("$1"); else module_remove "$1"; fi
  for n in "${MCP_ENABLED[@]}"; do [[ "$n" == "$1" ]] || kept+=("$n"); done
  MCP_ENABLED=("${kept[@]}")
}

# Required settings and secrets of every enabled module; a module without
# them is skipped (mcp_skip). Caller tokens are created when missing. Also
# collects images, session arguments, NO_PROXY hosts, remote hosts and the
# registrations to clean up.
mcp_check_secrets() {
  local name s missing server why rc taken=" "
  for name in "${MCP_ENABLED[@]}"; do
    rc=0; mcp_load "$name" || rc=$?
    if (( rc == 1 )); then
      mcp_skip "$name" "$MCP_PROBLEM"
      continue
    elif (( rc )); then
      mcp_skip "$name" "$MCP_PROBLEM" keep
      continue
    fi
    # Settings that do not check out: access goes, as for an emptied one.
    # The code of a manifest module runs here, in a subshell. For a broken
    # module (status 2), its sidecars stay (mcp_skip keep).
    rc=0; why=""
    if [[ "$MCP_FORMAT" == manifest ]]; then
      why="$(mcp_bind_check "$name")" || rc=$?
    elif declare -F mcp_check >/dev/null; then
      # Its status does not count, only what it prints.
      why="$(mcp_check || true)"
    fi
    if [[ -n "$why" ]]; then
      why="$(printf '%s\n' "$why" | head -3 | paste -sd ';' -)"
      if (( rc == 2 )); then mcp_skip "$name" "$why" keep; else mcp_skip "$name" "$why"; fi
      continue
    fi
    missing=()
    for s in ${MCP_SECRETS[@]+"${MCP_SECRETS[@]}"}; do
      secret_exists "$s" || missing+=("$s")
    done
    if (( ${#missing[@]} )); then
      mcp_skip "$name" "missing podman secrets ${missing[*]} (agentbox setup, or README, Setup in detail, step 5)"
      continue
    fi
    # A module whose servers are malformed, or named like those of a module
    # before it, is left out; only modules not left out for another reason
    # take names.
    rc=0; why="$(mcp_servers_problem "$name" "$taken")" || rc=$?
    if (( rc == 3 )); then
      # Its setting emptied: access goes, as for a module turned off.
      mcp_skip "$name" "$why"
      continue
    elif [[ -n "$why" ]]; then
      mcp_skip "$name" "$why" keep
      continue
    fi
    while IFS='|' read -r server _; do taken+="$server=$name "; done < <(mcp_servers)
  done
  mcp_collect
}

# Images, session arguments, NO_PROXY hosts, remote hosts and registrations
# of the enabled modules; caller tokens are created when missing.
mcp_collect() {
  local name host var h server url
  MCP_IMAGES_ALL=()
  MCP_SESSION_ARGS=()
  MCP_NO_PROXY=()
  MCP_EGRESS_ALL=()
  MCP_MANAGED=""
  for name in "${MCP_ENABLED[@]}"; do
    # Only modules that passed mcp_check_secrets: status 0.
    mcp_load_again "$name"
    if [[ -n "$MCP_CALLER_SECRET" ]]; then
      ensure_caller_secret "$MCP_CALLER_SECRET"
      var="$(mcp_token_var "$name")"
      MCP_SESSION_ARGS+=(--secret "$MCP_CALLER_SECRET,type=env,target=$var")
    fi
    MCP_IMAGES_ALL+=(${MCP_IMAGES[@]+"${MCP_IMAGES[@]}"})
    for h in ${MCP_EGRESS[@]+"${MCP_EGRESS[@]}"}; do MCP_EGRESS_ALL+=("$h $name"); done
    while IFS='|' read -r server url _; do
      # Sidecars are reached by container name, without the proxy. A host
      # the module lists in MCP_EGRESS is a remote server: through squid,
      # also when its name has no dot.
      host="${url#*://}"; host="${host%%[:/]*}"
      if [[ "$host" != *.* ]] && ! mcp_egress_has "$host"; then MCP_NO_PROXY+=("$host"); fi
      MCP_MANAGED+="$server $url"$'\n'
    done < <(mcp_servers)
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
  local claude="" pi="" server url auth desc
  mkdir -p "$dir"
  for name in "${MCP_ENABLED[@]}"; do
    mcp_load_again "$name"
    while IFS='|' read -r server url auth desc; do
      hdr=""
      # (mcp_servers_problem left out a caller server without the secret.)
      if [[ "$auth" == caller ]]; then
        hdr=", \"headers\": { \"Authorization\": \"Bearer \${$(mcp_token_var "$name")}\" }"
      fi
      claude+="$sep_c    $(json_str "$server"): { \"type\": \"http\", \"url\": $(json_str "$url")$hdr }"
      pi+="$sep_p    $(json_str "$server"): { \"url\": $(json_str "$url")$hdr, \"description\": $(json_str "$desc") }"
      sep_c=$',\n'; sep_p=$',\n'
    done < <(mcp_servers)
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
    mcp_load_again "$name"
    [[ "$MCP_FORMAT" == manifest && -f "$MCP_DIR/mcp.sh" ]] || declare -F mcp_start >/dev/null || continue
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
        # The code of a manifest module; its check ran in mcp_check_secrets.
        # Its reason, if any, goes where ab_error writes. Without fd 3, as
        # for mcp_start below: its top level can start a program.
        [[ "$MCP_FORMAT" != manifest ]] || mcp_bind "$name" >> "$errf" 3>&-
        declare -F mcp_start >/dev/null || exit 0
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
