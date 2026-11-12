# agentbox setup: a menu to edit config.toml (README, Setup menu).
#
#   agentbox setup
#
# Lists the MCP modules, skill sources, pi extensions and egress groups there are (shared
# and yours) with what is enabled, and agentbox's other settings; under a
# module, its settings and secrets and whether they are there. A number
# toggles an entry or edits a value; turning a module on asks for its
# settings and for the Podman secrets it lacks, "e <number>" asks for all of
# them again, replacing a secret only for a new value. Setup writes nothing
# before "s". Then config_set changes config.toml line by line. Comments
# and the order of the lines stay. For a key that is not set, setup uses
# its "#KEY =" line from the example. Setup keeps the old file as config.toml.bak, and stores
# the secrets. Setup does not change config.env of v0.1.x. Tokens never go into
# config.toml. A module may say what to type for a setting and a secret
# (MCP_SETTING_HELP, MCP_SECRET_HELP_OF) and how that becomes the secret
# (mcp_secret_value).
#
# Reads its input from stdin: piped input works too, for scripts and tests.
# Needs SCRIPT_DIR and lib/paths.sh, config.sh, sidecars.sh (secret_store),
# mcp.sh, egress.sh, skills.sh and pi-extensions.sh.

# Settings in "Other": key, kind (flag: on or unset; flagon: a flag that is
# on when unset; else a value), text.
SETUP_OTHER=(
  "AB_TRIVY flag Trivy in the box (rebuilds the image)"
  "AB_SERVICES value your dev containers the agent may reach, e.g. redis postgres"
  "AB_FORWARD value services outside the box, e.g. db=db.test.example:5432"
  "AB_PYTHON_VERSIONS value Python versions in the image, e.g. 3.12 3.13"
  "AB_GO_VERSION value Go version in the image (empty: latest)"
  "AB_GOLANGCI_LINT_VERSION value golangci-lint version (empty: latest)"
  "AB_GRAPHIFY_EXTRAS value graphify extras, e.g. [terraform]"
  "AB_UPDATE_EVERY value seconds between update checks (default 21600)"
  "AB_CHECK_UPDATES flagon update checks before a session (images, skills)"
)

# Pending changes: SETUP_NEW[key]="set <value>" or "unset"; secrets to store
# in SETUP_SECRETS[name]=value. The other variables are caches. A save
# empties them, and setup_prime fills them again: the values and places of
# config.toml (SETUP_FILE, SETUP_AT), the module info, the secrets, the list
# settings of the modules and the error of config.toml.
declare -A SETUP_NEW=() SETUP_SECRETS=() SETUP_FILE=() SETUP_AT=() SETUP_INFO=() SETUP_HAS=() SETUP_PROBLEM=()
SETUP_ERROR="" SETUP_LISTS=" "

# The value of <key> in config.toml, as run.sh reads it: "set <value>" or
# "unset". The environment does not count here. From setup_prime.
setup_file_value() {  # <key>
  echo "${SETUP_FILE[$1]:-unset}"
}

# Fills the caches, in this shell: every module's info, one read of
# config.toml for agentbox's keys and every module's, and the secrets there
# are. Run at the start and after a save.
setup_prime() {
  local n info keys=("${CONFIG_KEYS[@]}") more=() k line err
  # Once here, not in each setup_describe, which runs in a subshell. (Setup
  # stops before this without Python: TOML_PYTHON is already set.)
  toml_version
  while IFS= read -r n; do
    info="$(setup_module_info "$n")" || { SETUP_INFO[$n]="!"; continue; }
    SETUP_INFO[$n]="$info"
    read -ra more <<<"$(sed -n 2p <<<"$info")"
    keys+=(${more[@]+"${more[@]}"})
    SETUP_LISTS+="$(sed -n 8p <<<"$info") "
  done < <(mcp_names | sort)
  # A file with an error gives no values; the menu shows the error and continues.
  err="$(mktemp)" || return 1
  while IFS= read -r line; do
    k="${line%%$'\t'*}"
    if [[ "$k" == @* ]]; then SETUP_AT[${k#@}]="${line#*$'\t'}"; else SETUP_FILE[$k]="${line#*$'\t'}"; fi
  done < <(
    for k in "${keys[@]}"; do unset "$k"; done
    SETTING_AT=()
    [[ -f "$CONFIG_FILE" ]] && settings_load "$CONFIG_FILE" 0 "${keys[@]}" 2> "$err"
    for k in "${keys[@]}"; do
      if [[ -n "${!k+x}" ]]; then printf '%s\tset %s\n' "$k" "${!k}"; else printf '%s\tunset\n' "$k"; fi
    done
    for k in "${!SETTING_AT[@]}"; do printf '@%s\t%s\n' "$k" "${SETTING_AT[$k]}"; done
  )
  SETUP_ERROR="$(cat -- "$err")"
  rm -f -- "$err"
  # Again, now with the values of config.toml: a module's secrets can follow
  # a setting there (github: GH_OWNERS).
  SETUP_INFO=()
  while IFS= read -r n; do setup_module_info "$n" >/dev/null || true; done < <(mcp_names | sort)
  # Read anew after each save: a secret stored in a pipeline (setup_save)
  # does not reach this shell's list. A failed listing marks none, and the
  # menu still works on config.toml.
  if secret_ids_read 2>/dev/null; then
    for k in "${!SECRET_IDS[@]}"; do SETUP_HAS[$k]=1; done
  else
    echo "agentbox setup: cannot list the Podman secrets; they show as MISSING" >&2
  fi
}

setup_current() {  # <key>: "set <value>" or "unset", pending changes included
  if [[ -n "${SETUP_NEW[$1]+x}" ]]; then echo "${SETUP_NEW[$1]}"; else setup_file_value "$1"; fi
}
setup_get() {  # <key> [default when unset]
  local c; c="$(setup_current "$1")"
  if [[ "$c" == set* ]]; then echo "${c#set }"; else echo "${2:-}"; fi
}

setup_has_secret() {  # <secret>: 0 if it exists or one is pending
  [[ -n "${SETUP_SECRETS[$1]+x}" || -n "${SETUP_HAS[$1]+x}" ]]
}

# Records a change of <key>; one that brings back the file's value is no
# change. For a list setting of a module, the order and the commas do not
# count.
setup_record() {  # <key> <"set <value>" | unset>
  local f; f="$(setup_file_value "$1")"
  # A setting changed: the module info (its secrets can follow a setting)
  # and setup_module_problem are made again.
  SETUP_PROBLEM=(); SETUP_INFO=()
  if [[ "$2" == "$f" ]] || { in_list "$1" "$SETUP_LISTS" && [[ "$2" == set* && "$f" == set* ]] && same_set "${2#set }" "${f#set }"; }; then
    unset "SETUP_NEW[$1]"
  else
    SETUP_NEW[$1]="$2"
  fi
}

# The same names, whatever the order or the commas.
same_set() {  # <list> <list>
  [[ "$(tr ', ' '\n\n' <<<"$1" | sed '/^$/d' | sort -u)" == "$(tr ', ' '\n\n' <<<"$2" | sed '/^$/d' | sort -u)" ]]
}

# Records a list key (AB_MCP, AB_SKILLS, AB_PI_EXTENSIONS, AB_EGRESS) toggled to <list>: no
# change if it names what the file gives, the default for an unset key
# included, so an unset AB_EGRESS keeps following EGRESS_DEFAULT.
setup_record_list() {  # <key> <list> [default when unset]
  local f; f="$(setup_file_value "$1")"
  if [[ "$f" == set* ]] && same_set "${f#set }" "$2"; then unset "SETUP_NEW[$1]"
  elif [[ "$f" == unset ]] && same_set "${3:-}" "$2"; then unset "SETUP_NEW[$1]"
  else SETUP_NEW[$1]="set $2"; fi
}

# What an egress group opens: its hosts. What a skill source or a pi
# extension source is: its URL. "(yours)" for a file in your directory.
setup_describe() {  # <egress|skill|piext> <file>
  local text rc=0 err kind key
  local -A desc=()
  case "$1" in
    egress) kind=egress-group key=hosts ;;
    skill) kind=skill-source key=url ;;
    piext) kind=pi-extension-source key=url ;;
    *) echo "error: setup_describe: no kind '$1'" >&2; return 2 ;;
  esac
  if [[ "$2" == *.conf ]]; then
    text="(not converted, see the warning above)"
  else
    # In a subshell already ($(...)): the temp file goes with it.
    err="$(mktemp)"
    toml_load "$kind" "$2" desc 2>"$err" || rc=$?
    case "$rc" in
      0) text="${desc[$key]}" ;;
      *) text="$(head -n 1 "$err")"; text="(${text#"${2%/*}/"})" ;;
    esac
    rm -f -- "$err"
  fi
  (( ${#text} > 60 )) && text="${text:0:60}" && text="${text% *} ..."
  [[ "$2" == "$AB_HOME_DIR"/* ]] && text="(yours) $text"
  echo "$text"
}

# Names of <dir>/*.toml over all <dirs>, sorted, once each, and each old
# file of yours (the first dir) that is not converted (lib/convert.sh).
setup_names() {  # <extension> <dirs: yours, then shared>
  local ext="$1" d f yours="$2"
  shift
  for d in "$@"; do
    for f in "$d"/*."$ext"; do [[ -f "$f" ]] && basename "$f" ".$ext"; done
    if [[ "$ext" == toml && "$d" == "$yours" ]]; then
      for f in "$d"/*.conf; do convert_pending "$f" && basename "$f" .conf; done
    fi
  done | sort -u
}


# The info of a module, in eight lines:
#   1. the description
#   2. the settings (MCP_CONFIG)
#   3. the required settings
#   4. the secrets
#   5. the help of the secrets: "<secret>: <help>" entries, split by a tab
#   6. the help of the settings: "<KEY>: <help>" entries, split by a tab
#   7. the settings with no value that the module needs (MCP_MISSING)
#   8. the list settings (MCP_LIST_CONFIG)
# A subshell reads the module, so a broken module of yours does not stop
# the menu. Status 1 if mcp_load gives status 2 or more.
setup_module_info() {  # <name>
  if [[ -z "${SETUP_INFO[$1]+x}" ]]; then
    SETUP_INFO[$1]="$(
      rc=0; mcp_load "$1" >/dev/null 2>&1 || rc=$?
      (( rc <= 1 )) || exit 1
      # Its settings as they are now in the menu, then again: secrets and
      # servers can follow a setting (github: GH_OWNERS).
      setup_apply_settings ${MCP_CONFIG[@]+"${MCP_CONFIG[@]}"}
      rc=0; mcp_load "$1" >/dev/null 2>&1 || rc=$?
      (( rc <= 1 )) || exit 1
      echo "${MCP_DESCRIPTION:-}"
      echo "${MCP_CONFIG[*]-}"
      echo "${MCP_REQUIRED_CONFIG[*]-}"
      echo "${MCP_SECRETS[*]-}"
      # A tab or a new line in a help text would break the lines.
      breaks=$'\t\n'
      for k in "${!MCP_SECRET_HELP_OF[@]}"; do printf '%s: %s\t' "$k" "${MCP_SECRET_HELP_OF[$k]//[$breaks]/ }"; done; echo
      for k in "${!MCP_SETTING_HELP[@]}"; do printf '%s: %s\t' "$k" "${MCP_SETTING_HELP[$k]//[$breaks]/ }"; done; echo
      echo "${MCP_MISSING[*]-}"
      echo "${MCP_LIST_CONFIG[*]-}"
    )" 2>/dev/null || SETUP_INFO[$1]="!"
  fi
  [[ "${SETUP_INFO[$1]}" != "!" ]] && echo "${SETUP_INFO[$1]}"
}

# Line <n> of the module info (setup_module_info gives the lines).
setup_module_line() {  # <name> <n>
  setup_module_info "$1" | sed -n "${2}p"
}

# The help of <name> from line <n> of the module info; empty if none.
setup_help() {  # <module> <n> <name>
  local h
  while IFS= read -r h; do
    [[ "$h" == "$3: "* ]] && { echo "${h#"$3: "}"; return; }
  done < <(setup_module_line "$1" "$2" | tr '\t' '\n')
}

setup_secret_help() {  # <module> <secret>: what to type, from MCP_SECRET_HELP_OF
  local h; h="$(setup_help "$1" 5 "$2")"
  [[ -n "$h" ]] || h="see the module's README section"
  echo "$h"
}

# The value of secret <secret> for what was typed: the module's
# mcp_secret_value, or as typed. Also at mcp_load status 1: you can type
# the token before the setting is saved. The module code gets the settings
# as they are now in the menu.
setup_secret_value() {  # <module> <secret> <typed>
  (
    # shellcheck disable=SC2046  # the keys are words
    setup_apply_settings $(setup_module_line "$1" 2)
    rc=0; mcp_load "$1" >/dev/null 2>&1 || rc=$?
    (( rc <= 1 )) || exit 1
    [[ "$MCP_FORMAT" != manifest ]] || mcp_bind "$1" >/dev/null 2>&1 || exit 1
    if declare -F mcp_secret_value >/dev/null; then mcp_secret_value "$2" "$3"; else printf '%s' "$3"; fi
  )
}

# read -p shows its prompt only when the input is a terminal: printed
# here, it shows with piped input too.
setup_read() {  # <variable> <prompt> [-s]
  printf '%s' "$2"
  if [[ "${3:-}" == -s ]]; then
    IFS= read -r -s "$1" || return 1
    echo
  else
    IFS= read -r "$1" || return 1
  fi
}

in_list() { [[ " $2 " == *" $1 "* ]]; }   # <word> <list>
list_toggle() {  # <word> <list>: the list with <word> added or removed
  local w out=""
  if in_list "$1" "$2"; then
    for w in $2; do [[ "$w" == "$1" ]] || out+="$w "; done
  else
    out="$2 $1"
  fi
  out="${out# }"; echo "${out% }"
}

setup_ask_value() {  # <key> <text> [required]: asks, records in SETUP_NEW
  local key="$1" cur reply
  cur="$(setup_get "$key")"
  while :; do
    setup_read reply "  $key ($2) [${cur}]; Enter keeps it, - unsets: " || return 0
    reply="${reply#"${reply%%[![:space:]]*}"}"
    reply="${reply%"${reply##*[![:space:]]}"}"
    if [[ -z "$reply" ]]; then
      [[ -n "${3:-}" && -z "$cur" && -z "${!key:-}" ]] && { echo "  $key is needed"; continue; }
      return 0
    fi
    if [[ "$reply" == - ]]; then
      [[ -n "${3:-}" ]] && { echo "  $key is needed"; continue; }
      setup_record "$key" unset; return 0
    fi
    # config.toml refuses a control character in a value.
    if [[ "$reply" == *[[:cntrl:]]* ]]; then echo "  a value without control characters"; continue; fi
    if [[ "$key" == AB_UPDATE_EVERY && ! "$reply" =~ ^(0|[1-9][0-9]*)$ ]]; then echo "  a number of seconds"; continue; fi
    setup_record "$key" "set $reply"; return 0
  done
}

# Asks for secret <secret> of <module>: when missing, or with "replace"
# when it exists too, then a new value replaces it.
setup_ask_secret() {  # <secret> <module> [replace]
  local reply value prompt
  if setup_has_secret "$1"; then
    [[ -n "${3:-}" ]] || return 0
    local state=stored
    [[ -n "${SETUP_SECRETS[$1]+x}" ]] && state="entered, not saved yet"
    prompt="  secret $1 is $state; a new value replaces it ($(setup_secret_help "$2" "$1"); hidden; Enter keeps it): "
  else
    prompt="  secret $1 for $2 ($(setup_secret_help "$2" "$1"); hidden; Enter: later): "
  fi
  setup_read reply "$prompt" -s || reply=""
  reply="${reply#"${reply%%[![:space:]]*}"}"
  reply="${reply%"${reply##*[![:space:]]}"}"
  [[ -n "$reply" ]] || return 0
  if ! value="$(setup_secret_value "$2" "$1" "$reply")" || [[ -z "$value" ]]; then
    echo "  module $2 cannot make the secret from that; not stored"
    return 0
  fi
  SETUP_SECRETS[$1]="$value"
}

# Settings and secrets of module <name>; with "all", existing secrets too.
setup_module_settings() {  # <name> [all]
  local keys req missing k s h
  if ! setup_module_info "$1" >/dev/null; then echo "  module $1 cannot be read"; return; fi
  keys="$(setup_module_line "$1" 2)"; req="$(setup_module_line "$1" 3)"
  for k in $keys; do
    # In this shell: a changed setting empties the cache, and $(...) would
    # make the info again for each call.
    setup_module_info "$1" >/dev/null
    h="$(setup_help "$1" 6 "$k")"; missing="$(setup_module_line "$1" 7)"
    # A setting that the module needs but that is not required (a server
    # URL uses it) can stay empty for now.
    if in_list "$k" "$req"; then setup_ask_value "$k" "setting of $1${h:+: $h}" required
    elif in_list "$k" "$missing"; then setup_ask_value "$k" "setting of $1, needed${h:+: $h}"
    else setup_ask_value "$k" "setting of $1, optional${h:+: $h}"; fi
  done
  setup_module_info "$1" >/dev/null
  for s in $(setup_module_line "$1" 4); do setup_ask_secret "$s" "$1" ${2:+replace}; done
}

# Sets <keys> as they are now in the menu, saved or not; the environment
# wins, as for run.sh. SETTING_AT gets the place of each value: its line in
# config.toml, or "setup (not saved)". For a subshell that loads a module.
setup_apply_settings() {  # <keys...>
  local k v
  for k in "$@"; do
    [[ -n "${!k+x}" ]] && continue
    v="$(setup_get "$k")"
    [[ -n "$v" ]] || continue
    printf -v "$k" '%s' "$v"
    if [[ -n "${SETUP_NEW[$k]+x}" ]]; then SETTING_AT[$k]="setup (not saved)"; else SETTING_AT[$k]="${SETUP_AT[$k]:-}"; fi
  done
  return 0
}

# What run.sh would leave module <name> out for, with the settings as they
# are now in the menu (saved or not; the environment wins, as for run.sh):
# its mcp_check and its server lines (lib/mcp.sh), the first problem only.
# Nothing while a setting is missing (MCP_MISSING): the status says NEEDED.
# Kept in SETUP_PROBLEM[<name>] until a setting changes: call it in the
# menu's own shell, not in $(...), and read the array.
setup_module_problem() {  # <name>
  [[ -n "${SETUP_PROBLEM[$1]+x}" ]] || SETUP_PROBLEM[$1]="$(setup_module_problem_now "$1")"
}

setup_module_problem_now() {  # <name>
  (
    local v="" rc
    setup_module_info "$1" >/dev/null || exit 0
    # shellcheck disable=SC2046  # the keys are words
    setup_apply_settings $(setup_module_line "$1" 2)
    rc=0; mcp_load "$1" >/dev/null 2>&1 || rc=$?
    (( rc == 1 && ${#MCP_MISSING[@]} )) && exit 0
    (( rc == 1 )) && { echo "$MCP_PROBLEM"; exit 0; }
    (( rc == 0 )) || exit 0
    if [[ "$MCP_FORMAT" == manifest ]]; then
      v="$(mcp_bind_check "$1" 2>/dev/null)" || true
    elif declare -F mcp_check >/dev/null; then
      v="$(mcp_check 2>/dev/null || true)"
    fi
    v="${v%%$'\n'*}"
    [[ -z "$v" ]] || { echo "$v"; exit 0; }
    mcp_servers_problem "$1" " " 2>/dev/null || true
  ) 2>/dev/null | head -1
}

setup_module_warn() {  # <name>: says so when run.sh would leave it out
  local problem
  setup_module_problem "$1"; problem="${SETUP_PROBLEM[$1]}"
  [[ -z "$problem" ]] || echo "  note: agentbox leaves $1 out of the start until this is fixed: $problem"
}

# Forgets the pending settings and secrets of module <name>, turned off
# before they were saved.
setup_module_forget() {  # <name>
  local k
  for k in $(setup_module_line "$1" 4); do unset "SETUP_SECRETS[$k]"; done
  for k in $(setup_module_line "$1" 2); do unset "SETUP_NEW[$k]"; done
  # Its settings changed: its info (secrets from a setting) is made again.
  SETUP_INFO=(); SETUP_PROBLEM=()
}

# The status line under module <name>, number <n>: its settings, whether
# its secrets are there. Empty for a module with neither.
setup_module_status() {  # <name> <n>
  local keys missing secrets k v out="" problem
  keys="$(setup_module_line "$1" 2)"; missing="$(setup_module_line "$1" 7)"; secrets="$(setup_module_line "$1" 4)"
  problem="${SETUP_PROBLEM[$1]:-}"   # setup_show fills it
  [[ -n "$keys$secrets$problem" ]] || return 0
  for k in $keys; do
    v="$(setup_get "$k")"
    if [[ -n "${!k+x}" ]]; then out+=" · $k=${!k} (environment)"
    elif [[ -n "$v" ]]; then out+=" · $k=$v"
    elif in_list "$k" "$missing"; then out+=" · $k NEEDED"
    else out+=" · $k (default)"; fi
  done
  for k in $secrets; do
    if [[ -n "${SETUP_SECRETS[$k]+x}" ]]; then out+=" · secret $k: new"
    elif setup_has_secret "$k"; then out+=" · secret $k: stored"
    else out+=" · secret $k: MISSING"; fi
  done
  [[ -z "$problem" ]] || out+=" · NOT USABLE: $problem"
  if [[ -n "$keys$secrets" ]]; then echo "${out# · } · e $2"; else echo "${out# · }"; fi
}

# The menu, one entry per line: "<kind> <key or name>"; printed by
# setup_show, acted on by setup_act.
setup_entries() {
  local n
  # Line by line: a file name with a space or * stays one name.
  while IFS= read -r n; do [[ "$n" == context7 ]] || echo "mcp $n"; done < <(mcp_names | sort)
  while IFS= read -r n; do echo "skill $n"; done < <(setup_names toml "${SKILLS_SOURCE_DIRS[@]}")
  while IFS= read -r n; do echo "piext $n"; done < <(setup_names toml "${PI_EXTENSION_SOURCE_DIRS[@]}")
  while IFS= read -r n; do echo "egress $n"; done < <(setup_names toml "${EGRESS_DIRS[@]}")
  for n in "${SETUP_OTHER[@]}"; do echo "other ${n%% *}"; done
}

setup_show() {
  local i=0 kind name section="" mcp skills piexts egress mark text status entry key env="" keys=() more=()
  mcp="$(setup_get AB_MCP)"; mcp="${mcp//,/ }"
  skills="$(setup_get AB_SKILLS)"; skills="${skills//,/ }"
  piexts="$(setup_get AB_PI_EXTENSIONS)"; piexts="${piexts//,/ }"
  egress="$(setup_get AB_EGRESS "$EGRESS_DEFAULT")"; egress="${egress//,/ }"
  echo
  echo -n "agentbox setup: $CONFIG_FILE"
  (( ${#SETUP_NEW[@]} + ${#SETUP_SECRETS[@]} )) && echo -n " (changed, not saved)"
  echo
  [[ -z "$SETUP_ERROR" ]] || printf '  Setup cannot read %s:\n%s\n  Setup cannot save changes to settings until it can read the file.\n' "$CONFIG_FILE" "$SETUP_ERROR"
  while read -r kind name; do
    i=$((i + 1))
    status=""
    if [[ "$kind" != "$section" ]]; then
      section="$kind"
      case "$kind" in
        mcp) echo "MCP servers (AB_MCP; context7 is always on)" ;;
        skill) echo "Skill sources (AB_SKILLS)" ;;
        piext) echo "pi extensions (AB_PI_EXTENSIONS; code that pi runs: read it first)" ;;
        egress) echo "Hosts the agent may reach (AB_EGRESS)" ;;
        other) echo "Other settings" ;;
      esac
    fi
    case "$kind" in
      mcp) in_list "$name" "$mcp" && mark="[x]" || mark="[ ]"
           if text="$(setup_module_line "$name" 1)" && setup_module_info "$name" >/dev/null; then
             [[ "$(mcp_find "$name")" == "$USER_MCP_DIR/"* ]] && text="(yours) $text"
             setup_module_problem "$name"
             status="$(setup_module_status "$name" "$i")"
             read -ra more <<<"$(setup_module_line "$name" 2)"
             keys+=(${more[@]+"${more[@]}"})
           else
             text="(cannot be read)"
           fi ;;
      skill) in_list "$name" "$skills" && mark="[x]" || mark="[ ]"
             text="$(setup_describe skill "$(convert_toml_find "$name" "${SKILLS_SOURCE_DIRS[@]}")")" ;;
      piext) in_list "$name" "$piexts" && mark="[x]" || mark="[ ]"
             text="$(setup_describe piext "$(convert_toml_find "$name" "${PI_EXTENSION_SOURCE_DIRS[@]}")")" ;;
      egress) in_list "$name" "$egress" && mark="[x]" || mark="[ ]"
              text="$(setup_describe egress "$(convert_toml_find "$name" "${EGRESS_DIRS[@]}")")" ;;
      other)
        for entry in "${SETUP_OTHER[@]}"; do [[ "${entry%% *}" == "$name" ]] && break; done
        entry="${entry#* }"
        if [[ "${entry%% *}" == flag* ]]; then
          mark="[ ]"
          [[ "$(setup_get "$name")" == 1 || ( "${entry%% *}" == flagon && "$(setup_get "$name" 1)" != 0 ) ]] && mark="[x]"
          text="$name: ${entry#* }"
        else
          mark="   "
          text="$name=$(setup_get "$name")  (${entry#* })"
        fi
        ;;
    esac
    if [[ "$kind" != other && ! "$name" =~ $AB_NAME_RE ]]; then
      mark="[-]"; text="cannot be used: names are a-z, 0-9 and - only"; status=""
    fi
    printf '%3d %s %-14s %s\n' "$i" "$mark" "$([[ "$kind" == other ]] || echo "$name")" "$text"
    [[ -n "$status" ]] && printf '        %s\n' "$status"
  done < <(setup_entries)
  for key in "${CONFIG_KEYS[@]}" ${keys[@]+"${keys[@]}"}; do [[ -n "${!key+x}" ]] && env+=" $key"; done
  [[ -n "$env" ]] && echo "Note: set in your environment, which wins over config.toml:$env"
  echo "number: toggle or edit; e <number>: settings and secrets of a module; s: save; q: quit"
}

setup_act() {  # <number> [e]
  local kind name list entry
  kind=""; name=""
  read -r kind name < <(setup_entries | sed -n "${1}p")
  [[ -n "$kind" ]] || { echo "no entry $1"; return; }
  if [[ -n "${2:-}" && "$kind" != mcp ]]; then echo "  e is for MCP modules; $1 is not one"; return; fi
  if [[ "$kind" != other && ! "$name" =~ $AB_NAME_RE ]]; then
    echo "  '$name' cannot be used: run.sh takes names of a-z, 0-9 and - only; rename its file"; return
  fi
  case "$kind" in
    mcp)
      if [[ -n "${2:-}" ]]; then setup_module_settings "$name" all; setup_module_warn "$name"; return; fi
      list="$(setup_get AB_MCP)"; list="${list//,/ }"
      # One that cannot be read can only go: run.sh would stop on it.
      if ! in_list "$name" "$list" && ! setup_module_info "$name" >/dev/null; then
        echo "  module $name cannot be read (run agentbox to see why); not turned on"; return
      fi
      setup_record_list AB_MCP "$(list_toggle "$name" "$list")"
      if in_list "$name" "$list"; then setup_module_forget "$name"; else setup_module_settings "$name"; setup_module_warn "$name"; fi ;;
    skill)
      list="$(setup_get AB_SKILLS)"; list="${list//,/ }"
      setup_record_list AB_SKILLS "$(list_toggle "$name" "$list")" ;;
    piext)
      list="$(setup_get AB_PI_EXTENSIONS)"; list="${list//,/ }"
      setup_record_list AB_PI_EXTENSIONS "$(list_toggle "$name" "$list")" ;;
    egress)
      list="$(setup_get AB_EGRESS "$EGRESS_DEFAULT")"; list="${list//,/ }"
      setup_record_list AB_EGRESS "$(list_toggle "$name" "$list")" "$EGRESS_DEFAULT"
      if [[ "$name" == anthropic ]] && in_list anthropic "$list"; then
        echo "  note: Claude Code does not start without anthropic"
      fi ;;
    other)
      for entry in "${SETUP_OTHER[@]}"; do [[ "${entry%% *}" == "$name" ]] && break; done
      entry="${entry#* }"
      if [[ "${entry%% *}" == flagon ]]; then
        # On again, and the file does not set it: no change (on is the default).
        if [[ "$(setup_get "$name" 1)" != 0 ]]; then setup_record "$name" "set 0"
        elif [[ "$(setup_file_value "$name")" == unset ]]; then setup_record "$name" unset
        else setup_record "$name" "set 1"; fi
      elif [[ "${entry%% *}" == flag ]]; then
        if [[ "$(setup_get "$name")" == 1 ]]; then setup_record "$name" unset; else setup_record "$name" "set 1"; fi
      else
        setup_ask_value "$name" "${entry#* }"
      fi ;;
  esac
}

# Applies SETUP_NEW to <file> with config_set, one key at a time; stops at
# the first key that config_set refuses (it says why). 1 then. A list
# setting of a module (MCP_LIST_CONFIG) becomes an array.
setup_apply() {  # <file: a work copy of CONFIG_FILE>
  local key c CONFIG_SET_NAME="$CONFIG_FILE" CONFIG_SET_LISTS="$SETUP_LISTS"
  local -A check=()
  # Read the real file first: an error then names it, not the work copy.
  [[ ! -f "$CONFIG_FILE" ]] || toml_load config "$CONFIG_FILE" check || return 1
  for key in "${!SETUP_NEW[@]}"; do
    c="${SETUP_NEW[$key]}"
    if [[ "$c" == unset ]]; then config_set "$1" "$key" || return 1
    else config_set "$1" "$key" "${c#set }" || return 1; fi
  done
}

# Writes the pending changes. All changes go into a work copy, and one mv
# puts it over the file: a stop half way leaves the file as it was. A
# config.toml that is a link stays one: setup changes the file that it
# points to. On a failure, setup stores no secret and keeps the changes:
# "s" tries again.
setup_save() {
  local target work="" name failed="" note="$AB_HOME_DIR/.setup-toml-noted"
  if (( ${#SETUP_NEW[@]} + ${#SETUP_SECRETS[@]} == 0 )); then
    echo "agentbox: nothing to save"
    return 0
  fi
  if (( ${#SETUP_NEW[@]} )); then
    target="$(realpath -m -- "$CONFIG_FILE")"
    # The work copy: of the file, or of the example for a new file (mktemp
    # gives mode 600).
    # A Ctrl-C during the save removes the work copy; the file stays as it was.
    trap 'rm -f -- "$work" "$work".??????; exit 130' INT TERM
    if ! { mkdir -p -- "$(dirname -- "$target")" && work="$(mktemp "$target.XXXXXX")"; }; then
      failed=1
    elif [[ -f "$target" ]]; then
      cp -- "$target" "$work" && chmod --reference="$target" -- "$work" || failed=1
    else
      cp -- "$SCRIPT_DIR/config.toml.example" "$work" || failed=1
    fi
    [[ -z "$failed" ]] && { setup_apply "$work" || failed=1; }
    if [[ -z "$failed" && -f "$target" ]] && cmp -s -- "$work" "$target"; then
      rm -f -- "$work"
    elif [[ -z "$failed" && -f "$target" ]]; then
      if cp -p -- "$target" "$target.bak" && mv -f -- "$work" "$target"; then
        echo "agentbox: saved $CONFIG_FILE (the previous one is $target.bak)"
      else
        failed=1
      fi
    elif [[ -z "$failed" ]]; then
      mv -f -- "$work" "$target" && echo "agentbox: saved $CONFIG_FILE" || failed=1
    fi
    trap - INT TERM
    if [[ -n "$failed" ]]; then
      [[ -n "$work" ]] && rm -f -- "$work"
      echo "error: could not write $CONFIG_FILE; nothing saved" >&2
      return 1
    fi
    # Once: v0.1.x reads config.env, which setup no longer changes.
    if [[ -f "$CONFIG_OLD_FILE" && ! -e "$note" ]]; then
      echo "agentbox: note: setup now saves your settings only in $CONFIG_FILE. It does not change $CONFIG_OLD_FILE, which agentbox v0.1.x reads."
      { : > "$note"; } 2>/dev/null
    fi
  fi
  # Only the secrets that a module lists now, enabled or not: one typed
  # for an owner that was then taken out of GH_OWNERS is not stored, and
  # the save says so.
  local wanted=" " m
  while IFS= read -r m; do wanted+="$(setup_module_line "$m" 4) "; done < <(mcp_names | sort)
  for name in "${!SETUP_SECRETS[@]}"; do
    if [[ "$wanted" != *" $name "* ]]; then
      echo "agentbox: not storing the Podman secret $name: no module uses it now"
      unset "SETUP_SECRETS[$name]"
      continue
    fi
    if printf '%s' "${SETUP_SECRETS[$name]}" | secret_store "$name"; then
      echo "agentbox: stored the Podman secret $name"
      unset "SETUP_SECRETS[$name]"
    else
      echo "error: could not store the Podman secret $name" >&2
      failed=1
    fi
  done
  SETUP_NEW=(); SETUP_FILE=(); SETUP_AT=(); SETUP_HAS=(); SETUP_LISTS=" "
  setup_prime
  [[ -n "$failed" ]] && return 1
  echo "agentbox: the next agentbox start applies it; open sessions keep what they started with"
}

agentbox_setup() {
  local reply
  # The menu handles failures itself; many of its tests are meant to fail.
  set +e
  setup_prime
  while :; do
    setup_show
    setup_read reply "> " || reply=q
    reply="${reply#"${reply%%[![:space:]]*}"}"
    reply="${reply%"${reply##*[![:space:]]}"}"
    if [[ "$reply" =~ ^e\ ?([0-9]+)$ ]]; then setup_act "${BASH_REMATCH[1]}" e; continue; fi
    if [[ "$reply" =~ ^[0-9]+$ ]]; then setup_act "$reply"; continue; fi
    case "$reply" in
      s) setup_save && return 0 ;;
      q)
        if (( ${#SETUP_NEW[@]} + ${#SETUP_SECRETS[@]} )); then
          setup_read reply "quit without saving the changes? [y/N] " || reply=y
          [[ "$reply" == [yY]* ]] || continue
        fi
        return 0 ;;
      "") ;;
      *) echo "a number, e <number>, s or q" ;;
    esac
  done
}
