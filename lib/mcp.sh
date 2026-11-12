# MCP servers as modules: mcp/<name>/ (shared, in git) or
# <AB_HOME>/mcp.local/<name>/ (yours; wins over mcp/). AB_MCP in
# config.toml lists the enabled ones; context7 is always enabled.
#
# A module with module.toml (a manifest) describes itself as data:
# mcp_load_manifest reads it, and runs no code of the module. mcp_bind
# runs its mcp.sh, if it has one. The text below is about the old format,
# a module with only mcp.sh.
#
# A module of the old format is a bash file, sourced by run.sh on the host,
# so it is code with the same trust as run.sh: read a module before you
# enable it. It sets:
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
#                        setting KEY ("MY_TEAMS my_team_");
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
# line, for cleaning up old registrations). Needs lib/egress.sh
# (egress_host_ok) for mcp_load without --declared.

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
# exits. Status: 0 usable, 1 a setting fails or is missing (MCP_MISSING;
# for a manifest, MCP_FAILED too),
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
  MCP_PROBLEM=""; MCP_ONE_SERVER=""; MCP_FORMAT=""; MCP_MISSING=(); MCP_FAILED=(); MCP_LIST_CONFIG=(); MCP_FOR_EACH_SECRETS=()
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

# The required settings that are not set, into MCP_MISSING, for the old
# format. 1 if there are any, with the first one in MCP_PROBLEM. An empty
# value counts as not set.
mcp_missing() {
  local key
  for key in ${MCP_REQUIRED_CONFIG[@]+"${MCP_REQUIRED_CONFIG[@]}"}; do
    [[ -n "${!key:-}" ]] || MCP_MISSING+=("$key")
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

# The built-in checks of a setting (check = "<name>"), each with the fields
# that it gives to MCP_FIELD and to the substitutions.
declare -gA MCP_CHECKS=([url]="scheme host port hostport base" [url-base]="scheme host port hostport base"
  [port]="" [name]="" [file]="")

# One function for each check: mcp_valid_<check>, with "_" in place of
# "-". It checks one value. If the value fails, it sets why to the reason
# and returns 1. The url checks put their fields into fld. The caller
# declares why and fld as locals.
# shortcut: no IPv6 address and no IDN host in a URL, add them when a module needs one.
mcp_valid_url() {  # <value> [base: no path]
  local label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?' path re
  re='^(https?)://('"$label(\\.$label)*"')(:([1-9][0-9]{0,4}))?(/[A-Za-z0-9._~:/%+=,!*-]*)?$'
  if [[ ! "$1" =~ $re ]] || (( 10#${BASH_REMATCH[7]:-1} > 65535 )); then
    why="not an http:// or https:// URL: a host, an optional port from 1 to 65535 and an optional path, with no user@, query or fragment"
    return 1
  fi
  path="${BASH_REMATCH[8]}"
  if [[ -n "${2:-}" && -n "$path" && "$path" != / ]]; then
    why="not an http:// or https:// URL with no path"
    return 1
  fi
  fld=([scheme]="${BASH_REMATCH[1]}" [host]="${BASH_REMATCH[2]}" [port]="${BASH_REMATCH[7]}"
       [hostport]="${BASH_REMATCH[2]}${BASH_REMATCH[6]}")
  while [[ "$path" == */ ]]; do path="${path%/}"; done
  fld[base]="${fld[scheme]}://${fld[hostport]}$path"
}

mcp_valid_url_base() {  # <value>
  mcp_valid_url "$1" base
}

mcp_valid_port() {  # <value>
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )) && return
  why="not a port: a number from 1 to 65535, with no 0 at the start"
  return 1
}

mcp_valid_name() {  # <value>: the rule of a GitHub name
  [[ ${#1} -le 39 && "$1" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]] && return
  why="not a name: letters, digits and -, with no - at the start or the end, no --, and at most 39 characters"
  return 1
}

mcp_valid_file() {  # <value>
  [[ -f "$1" && -r "$1" ]] && return
  why="not a file that agentbox can read"
  return 1
}

# Expands the substitutions of <template> into sub, for mcp_load_manifest
# (its v, l and f): {SETTING}, {SETTING.field}, {item} with <item>, and
# {{ and }} for { and }. A setting goes in only when it has a check. A value
# with a |, a control character or a space gives an error. Status 2, with
# MCP_PROBLEM, for a bad template or value. <path> names the key.
# sub_unset lists the settings with no value that the template uses, and
# the settings in failed (of mcp_load_manifest), which give empty text.
mcp_manifest_subst() {  # <path> <template> [<item>]
  local t="$2" tok name key val why code=bad-substitution
  local re='^([^{}]*)(\{\{|\}\}|\{[^{}]*\}|\{|\})(.*)$' bad='[[:cntrl:]| ]'
  sub=""; sub_unset=""
  while [[ "$t" =~ $re ]]; do
    sub+="${BASH_REMATCH[1]}"; tok="${BASH_REMATCH[2]}"; t="${BASH_REMATCH[3]}"
    case "$tok" in
      '{{') sub+='{'; continue ;;
      '}}') sub+='}'; continue ;;
    esac
    name="${tok:1:${#tok}-1}"; name="${name%\}}"; key="${name%%.*}"; val=""
    if (( ${#tok} <= 2 )); then why="'$tok' is not a substitution: write {{ and }} for { and }"
    elif [[ "$name" == item ]]; then
      (( $# > 2 )) || why="{item} needs for_each in its table"
      val="${3:-}"
    elif [[ " ${MCP_CONFIG[*]-} " != *" $key "* ]]; then why="{$name}: $key is not a setting of the manifest"
    elif [[ -z "${v[settings.$key.check]:-}" ]]; then why="{$name}: the setting $key has no check"; code="unchecked-setting"
    elif [[ "${failed-}" == *" $key "* ]]; then sub_unset+="$key "  # it failed its check: empty text
    elif [[ "$name" == "$key" ]]; then val="${MCP_VALUE[$key]-}"
    elif [[ " ${MCP_LIST_CONFIG[*]-} " == *" $key "* || " ${MCP_CHECKS[${v[settings.$key.check]}]} " != *" ${name#*.} "* ]]; then
      why="{$name}: the check of $key gives no field ${name#*.}"
    else val="${MCP_FIELD[$name]-}"
    fi
    if [[ -z "${why:-}" && "$val" =~ $bad ]]; then why="{$name}: the value has a |, a control character or a space"; code="bad-value"; fi
    if [[ -n "${why:-}" ]]; then
      MCP_PROBLEM="$(mcp_manifest_at "$1"): $1: $why ($code)"
      return 2
    fi
    [[ "$name" == item || -n "${MCP_VALUE[$key]-}" ]] || sub_unset+="$key "
    sub+="$val"
  done
  sub+="$t"
}

# Adds <key> to MCP_MISSING and MCP_FAILED, one time, for mcp_load_manifest.
mcp_manifest_missing() {  # <key>
  [[ " ${MCP_MISSING[*]-} " != *" $1 "* ]] || return 0
  MCP_MISSING+=("$1")
  MCP_FAILED+=("$1: missing-setting")
  [[ -n "$MCP_PROBLEM" ]] || MCP_PROBLEM="it needs $1 in $CONFIG_FILE (agentbox setup)"
}

# The path that has the line of the header of [secrets.<name>], for
# mcp_manifest_at: a key in the table, or the name record (the line of
# the first table of secrets).
mcp_manifest_secret_at() {  # <name>
  local at="secrets.$1.help"
  [[ -n "${l[$at]+x}" ]] || at="secrets.$1.for_each"
  [[ -n "${l[$at]+x}" || "${v[secrets]%% *}" != "$1" ]] || at=secrets
  echo "$at"
}

# The items of the setting that the for_each at <path> names, into items,
# for mcp_load_manifest. The setting needs list = true and a check.
mcp_manifest_items() {  # <path>
  local key="${v[$1]}"
  items=()
  if [[ " ${MCP_LIST_CONFIG[*]-} " != *" $key "* ]]; then
    MCP_PROBLEM="$(mcp_manifest_at "$1"): $1: '$key' is not a setting with list = true (bad-substitution)"
    return 2
  elif [[ -z "${v[settings.$key.check]:-}" ]]; then
    MCP_PROBLEM="$(mcp_manifest_at "$1"): $1: the setting $key has no check (unchecked-setting)"
    return 2
  fi
  read -ra items <<<"${MCP_ITEMS[$key]-}"
}

# The manifest adapter of mcp_load: reads $MCP_DIR/module.toml and runs no
# module code. A broken manifest gives status 2, and MCP_PROBLEM is
# "<file>:<line>: <reason> (<code>)" (tests/manifest/README lists the
# codes). MCP_LIST_CONFIG has the keys with list = true. Without
# --declared, also the resolved part: MCP_VALUE (the setting values after
# the defaults, lowercase and the split of the lists), MCP_FIELD,
# MCP_ITEMS, the for_each secrets (also in MCP_FOR_EACH_SECRETS),
# MCP_SERVERS and MCP_EGRESS. A setting that fails its check or is missing
# gives status 1. The for_each secrets of each list setting that passed
# its check are still set. MCP_FAILED has "<KEY>: <code>" for each failed
# setting, and MCP_PROBLEM the first reason,
# "<place>: <KEY>: <reason> (<check>)". The place is SETTING_AT
# (lib/config.sh), "environment", or the line of the manifest for a default.
mcp_load_manifest() {  # <name> [--declared]
  local f="$MCP_DIR/module.toml" rc=0 k i n name desc auth at names=" " c val it seen sub sub_unset unset fe url why failed=" " nfailed
  local -a items=() all=() each=()
  local -A v=() l=() fld=()
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
    [[ "${v[settings.$k.list]:-}" != 1 ]] || MCP_LIST_CONFIG+=("$k")
    [[ -z "${v[settings.$k.help]:-}" ]] || MCP_SETTING_HELP[$k]="${v[settings.$k.help]}"
    c="${v[settings.$k.check]:-}"
    if [[ -n "$c" && -z "${MCP_CHECKS[$c]+x}" ]]; then
      MCP_PROBLEM="$(mcp_manifest_at "settings.$k.check"): settings.$k.check: '$c' is not a check: use url, url-base, port, name or file (unknown-check)"
      return 2
    fi
  done
  for k in ${v[secrets]:-}; do
    if [[ "$k" == mcp_caller ]]; then
      at="$(mcp_manifest_secret_at mcp_caller)"
      MCP_PROBLEM="$(mcp_manifest_at "$at"): secrets.mcp_caller: agentbox makes this secret for a server with caller = true; remove it (reserved-secret)"
      return 2
    fi
    # The resolved part adds the secrets with for_each.
    [[ -z "${v[secrets.$k.for_each]+x}" ]] || continue
    if [[ "$k" == *"{"* ]]; then
      MCP_PROBLEM="$(mcp_manifest_at "$(mcp_manifest_secret_at "$k")"): secrets.$k: {item} needs for_each in its table (bad-substitution)"
      return 2
    fi
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
  # The templates, with no values yet: a bad one is an error of the
  # manifest, also with --declared and before a setting fails.
  for k in ${v[secrets]:-}; do
    [[ -n "${v[secrets.$k.for_each]+x}" ]] || continue
    if [[ "$k" != *"{item}"* ]]; then
      MCP_PROBLEM="$(mcp_manifest_at "secrets.$k.for_each"): secrets.$k: a secret with for_each needs {item} in its name (bad-secret-name)"
      return 2
    fi
    mcp_manifest_items "secrets.$k.for_each" || return 2
    mcp_manifest_subst "secrets.$k.help" "${v[secrets.$k.help]:-}" x || return 2
  done
  for (( i = 0; i < n; i++ )); do
    each=()
    if [[ -n "${v[servers.$i.for_each]+x}" ]]; then
      mcp_manifest_items "servers.$i.for_each" || return 2
      each=(x)
    fi
    for k in name url description; do
      mcp_manifest_subst "servers.$i.$k" "${v[servers.$i.$k]:-}" ${each[@]+"${each[@]}"} || return 2
    done
  done
  read -ra all <<<"${v[egress]:-}"
  for k in ${all[@]+"${all[@]}"}; do mcp_manifest_subst egress "$k" || return 2; done
  [[ "${2:-}" != --declared ]] || return 0
  for k in ${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"}; do
    val="${!k:-}"
    at="${SETTING_AT[$k]:-environment}"
    if [[ -z "$val" ]]; then
      val="${v[settings.$k.default]:-}"
      at="$(mcp_manifest_at "settings.$k.default")"
    fi
    [[ "${v[settings.$k.lowercase]:-}" != 1 ]] || val="${val,,}"
    items=("$val")
    if [[ " ${MCP_LIST_CONFIG[*]-} " == *" $k "* ]]; then
      # A list: an array (its items joined with a comma) or a string with
      # spaces or commas. Each item once.
      read -ra all <<<"${val//,/ }"
      items=(); seen=" "
      for it in ${all[@]+"${all[@]}"}; do
        [[ "$seen" == *" $it "* ]] || { items+=("$it"); seen+="$it "; }
      done
      MCP_ITEMS[$k]="${items[*]-}"
      val="${MCP_ITEMS[$k]// /,}"
    fi
    MCP_VALUE[$k]="$val"
    if [[ -z "$val" ]]; then
      [[ " ${MCP_REQUIRED_CONFIG[*]-} " != *" $k "* ]] || { mcp_manifest_missing "$k"; failed+="$k "; }
      continue
    fi
    c="${v[settings.$k.check]:-}"
    [[ -n "$c" ]] || continue
    for it in "${items[@]}"; do
      fld=()
      "mcp_valid_${c//-/_}" "$it" && continue
      MCP_FAILED+=("$k: $c")
      failed+="$k "
      [[ -n "$MCP_PROBLEM" ]] || MCP_PROBLEM="$at: $k: $why ($c)"
      continue 2
    done
    # The fields of a list would be the fields of one item only.
    [[ -z "${MCP_ITEMS[$k]+x}" ]] || continue
    for it in "${!fld[@]}"; do MCP_FIELD[$k.$it]="${fld[$it]}"; done
  done
  # The secrets with for_each of a list that passed its check, also at
  # status 1: setup shows them (the github owner tokens).
  for k in ${v[secrets]:-}; do
    [[ -n "${v[secrets.$k.for_each]+x}" && "$failed" != *" ${v[secrets.$k.for_each]} "* ]] || continue
    mcp_manifest_items "secrets.$k.for_each" || return 2
    for it in ${items[@]+"${items[@]}"}; do
      mcp_manifest_subst "secrets.$k.for_each" "$k" "$it" || return 2
      name="$sub"
      # A check such as url lets characters through that a Podman name
      # cannot have. A name must not be the name of another secret.
      if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ || -n "${MCP_SECRET[$name]+x}" ]]; then
        MCP_PROBLEM="$(mcp_manifest_at "secrets.$k.for_each"): secrets.$k: '$name' is not a secret name, or another secret has it (bad-secret-name)"
        return 2
      fi
      MCP_SECRET[$name]="$1_$name"
      MCP_SECRETS+=("$1_$name")
      MCP_FOR_EACH_SECRETS+=("$1_$name")
      [[ -n "${v[secrets.$k.help]:-}" ]] || continue
      mcp_manifest_subst "secrets.$k.help" "${v[secrets.$k.help]}" "$it" || return 2
      MCP_SECRET_HELP_OF[$1_$name]="$sub"
    done
  done
  # After a failed check, the servers only add their missing settings: the
  # menu then shows all of them as NEEDED.
  nfailed=${#MCP_FAILED[@]}
  for (( i = 0; i < n; i++ )); do
    fe=""; items=("")
    if [[ -n "${v[servers.$i.for_each]+x}" ]]; then
      # A list that failed its check gives no servers.
      [[ "$failed" != *" ${v[servers.$i.for_each]} "* ]] || continue
      fe=1
      mcp_manifest_items "servers.$i.for_each" || return 2
    fi
    for it in ${items[@]+"${items[@]}"}; do
      mcp_manifest_subst "servers.$i.name" "${v[servers.$i.name]}" ${fe:+"$it"} || return 2
      name="$sub"; unset="$sub_unset"
      mcp_manifest_subst "servers.$i.url" "${v[servers.$i.url]}" ${fe:+"$it"} || return 2
      url="$sub"; unset+="$sub_unset"
      # A setting with no value in a name or URL is missing (status 1).
      if [[ -n "$unset" ]]; then
        # A setting that failed its check is not missing.
        for k in $unset; do [[ "$failed" == *" $k "* ]] || mcp_manifest_missing "$k"; done
        continue
      fi
      (( ! nfailed )) || continue
      if [[ ! "$name" =~ $AB_NAME_RE ]]; then
        MCP_PROBLEM="$(mcp_manifest_at "servers.$i.name"): servers.$i.name: '$name' is not a server name: use lowercase letters, digits and - (bad-server-name)"
        return 2
      fi
      if [[ "$names" == *" $name "* ]]; then
        MCP_PROBLEM="$(mcp_manifest_at "servers.$i.name"): servers.$i.name: the server '$name' is in the manifest two times (duplicate-server)"
        return 2
      fi
      names+="$name "
      desc="$MCP_DESCRIPTION"; at=description
      if [[ -n "${v[servers.$i.description]+x}" ]]; then
        mcp_manifest_subst "servers.$i.description" "${v[servers.$i.description]}" ${fe:+"$it"} || return 2
        desc="$sub"; at="servers.$i.description"
      fi
      # The name check above refuses a | in a name.
      if [[ "$url" == *"|"* || "$desc" == *"|"* ]]; then
        [[ "$url" != *"|"* ]] || at="servers.$i.url"
        MCP_PROBLEM="$(mcp_manifest_at "$at"): $at: a server cannot have a | in its URL or description (pipe-in-server)"
        return 2
      fi
      auth=-
      [[ "${v[servers.$i.caller]:-}" != 1 ]] || auth=caller
      MCP_SERVERS+=("$name|$url|$auth|$desc")
    done
  done
  (( ! ${#MCP_FAILED[@]} )) || return 1
  read -ra all <<<"${v[egress]:-}"
  for k in ${all[@]+"${all[@]}"}; do
    mcp_manifest_subst egress "$k" || return 2
    # A setting that is not set gives no host.
    [[ -z "$sub_unset" ]] || continue
    # lib/egress.sh would stop the start for all modules.
    if ! egress_host_ok "$sub"; then
      MCP_PROBLEM="$(mcp_manifest_at egress): egress: '$sub' is not a host name, .domain or host:port (bad-egress-host)"
      return 2
    fi
    MCP_EGRESS+=("$sub")
  done
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
  # pass ignores them without a warning. Each manifest module that loads
  # also gets its cache index. Each name once, as mcp_find finds
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
      if mcp_load "$name" --declared; then
        keys=(${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"})
        mcp_index_save "$name" || ab_warn "cannot write the index of MCP module '$name': agentbox uninstall can leave its secrets"
      fi
    else
      read -ra keys <<<"$(mcp_config_keys_text "$d/mcp.sh")"
    fi
    MCP_QUIET_KEYS+=(${keys[@]+"${keys[@]}"})
  done < <(mcp_names)
}

# The index of a manifest module: a snapshot of its declared part, so that
# agentbox uninstall finds its images and secrets without Python. It is a
# data contract (also for a later Go core). Format 1: pairs of fields, each
# field ends with a NUL ("<key>\0<value>\0"), the keys in this order:
#   index.format      1
#   manifest.sha      the sha256 of module.toml, in hex
#   images            the images, split by a space
#   secrets           the Podman names of the secrets without for_each
#   own_secrets       the Podman names of the own secrets
#   caller_secret     the Podman name of the caller token, or empty
#   secrets.for_each  the Podman names that agentbox made through for_each,
#                     sorted, each once. agentbox adds names. Only
#                     uninstall removes them.
# A list is empty when the module has none. A reader ignores a key that it
# does not know. A file that agentbox setup made before the first start
# has index.format and secrets.for_each only. The places:
#   <cache>/agentbox/modules/<name>   mcp_init, mcp_check_secrets and
#                                     agentbox setup write it
#   mcp/<name>/module.index           in git, for each shared manifest;
#                                     release.sh --index writes it, with
#                                     no for_each names
# The index of the module that mcp_load --declared loaded, with the given
# for_each names, on stdout.
mcp_index() {  # [<for_each name>...]
  local sha
  sha="$(sha256sum < "$MCP_DIR/module.toml")"
  printf '%s\0' index.format 1 manifest.sha "${sha%% *}" images "${MCP_IMAGES[*]-}" secrets "${MCP_SECRETS[*]-}" \
    own_secrets "${MCP_OWN_SECRETS[*]-}" caller_secret "$MCP_CALLER_SECRET" secrets.for_each "$(mcp_index_names "$@")"
}

mcp_index_names() {  # [<for_each name>...]: sorted, each once, on one line
  printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -
}

# Writes the cache index of module <name>. It keeps the for_each names of
# the earlier file. Without --add, the other pairs come from the module
# that mcp_load --declared loaded. With --add, it adds the given for_each
# names and copies each other pair of the earlier file, also a pair that
# this version does not know. The lock stops two starts at the same time
# from losing names. Status 1 when it cannot write the file: the caller
# warns and continues, because only uninstall needs the index.
mcp_index_save() {  # <name> [--add <for_each name>...]
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/modules" f k v lock tmp rc=0
  local -a names=() order=()
  local -A old=()
  f="$dir/$1"
  { mkdir -p "$dir" && exec {lock}>> "$dir.lock"; } 2>/dev/null || return 1
  if ! flock "$lock" || ! tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)"; then
    exec {lock}>&-
    return 1
  fi
  if [[ -f "$f" ]]; then
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      [[ -n "${old[$k]+x}" ]] || order+=("$k")
      old[$k]="$v"
    done < "$f" || rc=1
  fi
  read -ra names <<<"${old[secrets.for_each]-}"
  if (( rc )); then
    :
  elif [[ "${2:-}" == --add ]]; then
    [[ -n "${old[index.format]+x}" ]] || order=(index.format ${order[@]+"${order[@]}"})
    [[ -n "${old[secrets.for_each]+x}" ]] || order+=(secrets.for_each)
    old[index.format]="${old[index.format]:-1}"
    old[secrets.for_each]="$(mcp_index_names ${names[@]+"${names[@]}"} "${@:3}")"
    for k in "${order[@]}"; do printf '%s\0' "$k" "${old[$k]}"; done > "$tmp" || rc=1
  else
    mcp_index ${names[@]+"${names[@]}"} > "$tmp" || rc=1
  fi
  (( rc )) || mv -f -- "$tmp" "$f" 2>/dev/null || rc=1
  (( ! rc )) || rm -f -- "$tmp"
  exec {lock}>&-
  return "$rc"
}

# The index files of the shared modules in <tree>: mcp/<name>/module.index
# for each module with module.toml (release.sh --index). It removes a
# module.index with no module.toml next to it. With --check (the drift
# check), it writes nothing. Then it returns 1 when a file is missing, is
# not the index of its manifest, or has no manifest.
mcp_index_tree() {  # <tree> [--check]
  local d name rc=0
  local -a MCP_DIRS=("$1/mcp")
  for d in "$1"/mcp/*/module.index; do
    [[ -f "$d" && ! -f "${d%/*}/module.toml" ]] || continue
    name="${d%/module.index}"; name="${name##*/}"
    if [[ "${2:-}" != --check ]]; then
      rm -f -- "$d"
      echo "removed mcp/$name/module.index"
    else
      echo "error: mcp/$name/module.index has no module.toml: run release.sh --index" >&2
      rc=1
    fi
  done
  for d in "$1"/mcp/*/module.toml; do
    [[ -f "$d" ]] || continue
    d="${d%/module.toml}"; name="${d##*/}"
    if ! mcp_load "$name" --declared; then
      echo "error: MCP module '$name': $MCP_PROBLEM" >&2
      rc=1
    elif [[ "${2:-}" != --check ]]; then
      mcp_index > "$d/module.index"
      echo "wrote mcp/$name/module.index"
    elif ! cmp -s <(mcp_index) "$d/module.index"; then
      echo "error: mcp/$name/module.index is missing or is not the index of its module.toml: run release.sh --index" >&2
      rc=1
    fi
  done
  return "$rc"
}

# The images or the secrets of the manifest modules, for agentbox
# uninstall: names on stdout, what it cannot find on stderr. Without
# Python, the names come from the index files: mcp/<name>/module.index of
# this release and the cache files, also the file of a module that is gone.
# With Python, also from each manifest, and the for_each secrets of the
# settings in <values> (the values of config.toml; no <values>: agentbox
# cannot read UNINSTALL_CONFIG). A module of the old format is not here (uninstall reads
# its mcp.sh as text). Needs lib/egress.sh (egress_host_ok).
mcp_uninstall_names() {  # images|secrets [<values>]
  local fields=images d f k v name cache="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/modules"
  # <the reason>, <the module>: for_each secrets that can stay.
  local keep="agentbox: %s, so it removes only the secrets of the list settings of MCP module '%s' that its index has. If you have other such secrets, remove them yourself (podman secret ls).\n"
  local -a dirs=("${MCP_DIRS[@]}") MCP_DIRS=() names=() w=()
  [[ "$1" == images ]] || fields="secrets own_secrets caller_secret secrets.for_each"
  for f in "$SCRIPT_DIR"/mcp/*/module.index "$cache"/*; do
    name="${f%/module.index}"; name="${name##*/}"
    # A name with a dot is a temporary file of mcp_index_save.
    [[ -f "$f" && "$name" =~ $AB_NAME_RE ]] || continue
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      [[ " $fields " != *" $k "* ]] || { read -ra w <<<"$v"; names+=(${w[@]+"${w[@]}"}); }
    done < "$f"
  done
  for d in "${dirs[@]}"; do
    # One directory at a time: a module of yours and the shared one of that
    # name both count.
    MCP_DIRS=("$d")
    for f in "$d"/*/module.toml; do
      name="${f%/module.toml}"; name="${name##*/}"
      [[ -f "$f" && "$name" =~ $AB_NAME_RE ]] || continue
      if ! mcp_load "$name" --declared; then
        # The release index is of the shared module, not of yours.
        if [[ -f "$cache/$name" || ( "$d" != "$USER_MCP_DIR" && -f "$SCRIPT_DIR/mcp/$name/module.index" ) ]]; then
          # The index has only the for_each names of the starts and of
          # setup, not those of a token from before v0.2.1.
          [[ "$1" != secrets ]] || ! grep -qE '^[[:space:]]*for_each[[:space:]]*=' "$f" ||
            printf "$keep" "$MCP_PROBLEM" "$name" >&2
        else
          echo "agentbox: $MCP_PROBLEM. There is no index of MCP module '$name' (in $SCRIPT_DIR/mcp or $cache) either, so agentbox keeps its $1. If they are on this host, remove them yourself (podman ${1/secrets/secret ls})." >&2
        fi
        continue
      fi
      if [[ "$1" == images ]]; then
        names+=(${MCP_IMAGES[@]+"${MCP_IMAGES[@]}"})
        continue
      fi
      names+=(${MCP_SECRETS[@]+"${MCP_SECRETS[@]}"} ${MCP_OWN_SECRETS[@]+"${MCP_OWN_SECRETS[@]}"} "$MCP_CALLER_SECRET")
      (( ${#MCP_LIST_CONFIG[@]} )) || continue
      if [[ -z "${2:-}" ]]; then
        printf "$keep" "agentbox cannot read ${UNINSTALL_CONFIG:-config.toml}" "$name" >&2
        continue
      fi
      # The for_each secrets from the values in config.toml, not from the
      # environment.
      mapfile -t -O "${#names[@]}" names < <(
        local -n values="$2"
        for k in "${MCP_CONFIG[@]}"; do
          unset "$k" 2>/dev/null || true
          [[ -z "${values[$k]+x}" ]] || printf -v "$k" '%s' "${values[$k]}"
        done
        mcp_load "$name" || true
        # A list setting that fails its check gives no names.
        for k in ${MCP_FAILED[@]+"${MCP_FAILED[@]}"}; do
          [[ " ${MCP_LIST_CONFIG[*]} " != *" ${k%%:*} "* ]] || { printf "$keep" "$MCP_PROBLEM" "$name" >&2; break; }
        done
        printf '%s\n' ${MCP_FOR_EACH_SECRETS[@]+"${MCP_FOR_EACH_SECRETS[@]}"}
      )
    done
  done
  printf '%s\n' ${names[@]+"${names[@]}"} | grep -E '^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$' | sort -u || true
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
    # Also before the secrets exist: uninstall removes the names that exist.
    if (( ${#MCP_FOR_EACH_SECRETS[@]} )) && ! mcp_index_save "$name" --add "${MCP_FOR_EACH_SECRETS[@]}"; then
      ab_warn "cannot write the index of MCP module '$name': agentbox uninstall can leave its secrets"
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
