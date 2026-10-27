# agentbox setup: a menu to edit config.env (README, Setup menu).
#
#   agentbox setup
#
# Lists the MCP modules, skill sources and egress groups there are (shared
# and yours) with what is enabled, and agentbox's other settings; under a
# module, its settings and secrets and whether they are there. A number
# toggles an entry or edits a value; turning a module on asks for its
# settings and for the Podman secrets it lacks, "e <number>" asks for all of
# them again, replacing a secret only for a new value. Nothing is written
# before "s": then config.env is edited in place (comments and order stay;
# a "#KEY=" line from the example is used where the key is not set yet),
# the old file kept as config.env.bak, and the secrets stored. Tokens never
# go into config.env. A module may say what to type for a secret
# (MCP_SECRET_HELP) and how that becomes the secret (mcp_secret_value).
#
# Reads its input from stdin: piped input works too, for scripts and tests.
# Needs SCRIPT_DIR and lib/paths.sh, config.sh, sidecars.sh (secret_store),
# mcp.sh, egress.sh and skills.sh.

# Settings in "Other": key, kind (flag: 1 or unset; else a value), text.
SETUP_OTHER=(
  "AB_TRIVY flag Trivy in the box (rebuilds the image)"
  "AB_SERVICES value your dev containers the agent may reach, e.g. redis postgres"
  "AB_FORWARD value services outside the box, e.g. db=db.test.example:5432"
  "AB_PYTHON_VERSIONS value Python versions in the image, e.g. 3.12 3.13"
  "AB_GO_VERSION value Go version in the image (empty: latest)"
  "AB_GOLANGCI_LINT_VERSION value golangci-lint version (empty: latest)"
  "AB_GRAPHIFY_EXTRAS value graphify extras, e.g. [terraform]"
  "AB_UPDATE_EVERY value seconds between update checks (default 21600)"
  "AB_CHECK_UPDATES value 0: no update check before a session"
)

# Pending changes: SETUP_NEW[key]="set <value>" or "unset"; secrets to store
# in SETUP_SECRETS[name]=value. Caches for one run of the menu, emptied when
# saved: what config.env holds, module info, which secrets exist.
declare -A SETUP_NEW=() SETUP_SECRETS=() SETUP_FILE=() SETUP_INFO=() SETUP_HAS=()

# The value of <key> in config.env, as run.sh reads it: "set <value>" or
# "unset". The environment does not count here. From setup_prime.
setup_file_value() {  # <key>
  echo "${SETUP_FILE[$1]:-unset}"
}

# Fills the caches, in this shell: every module's info, one read of
# config.env for agentbox's keys and every module's, and the secrets there
# are. Run at the start and after a save.
setup_prime() {
  local n info keys=("${CONFIG_KEYS[@]}") k line
  while IFS= read -r n; do
    info="$(setup_module_info "$n")" || { SETUP_INFO[$n]="!"; continue; }
    SETUP_INFO[$n]="$info"
    keys+=($(sed -n 2p <<<"$info"))
  done < <(setup_names mcp "${MCP_DIRS[@]}")
  while IFS= read -r line; do
    SETUP_FILE[${line%%$'\t'*}]="${line#*$'\t'}"
  done < <(
    for k in "${keys[@]}"; do unset "$k"; done
    [[ -f "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE" 0 "${keys[@]}"
    for k in "${keys[@]}"; do
      if [[ -n "${!k+x}" ]]; then printf '%s\tset %s\n' "$k" "${!k}"; else printf '%s\tunset\n' "$k"; fi
    done
  )
  while IFS= read -r k; do
    [[ -n "$k" ]] && SETUP_HAS[$k]=1
  done < <(podman secret ls --format '{{.Name}}' 2>/dev/null)
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
# change.
setup_record() {  # <key> <"set <value>" | unset>
  if [[ "$2" == "$(setup_file_value "$1")" ]]; then unset "SETUP_NEW[$1]"; else SETUP_NEW[$1]="$2"; fi
}

# The same names, whatever the order or the commas.
same_set() {  # <list> <list>
  [[ "$(tr ', ' '\n\n' <<<"$1" | sed '/^$/d' | sort -u)" == "$(tr ', ' '\n\n' <<<"$2" | sed '/^$/d' | sort -u)" ]]
}

# Records a list key (AB_MCP, AB_SKILLS, AB_EGRESS) toggled to <list>: no
# change if it names what the file gives, the default for an unset key
# included, so an unset AB_EGRESS keeps following EGRESS_DEFAULT.
setup_record_list() {  # <key> <list> [default when unset]
  local f; f="$(setup_file_value "$1")"
  if [[ "$f" == set* ]] && same_set "${f#set }" "$2"; then unset "SETUP_NEW[$1]"
  elif [[ "$f" == unset ]] && same_set "${3:-}" "$2"; then unset "SETUP_NEW[$1]"
  else SETUP_NEW[$1]="set $2"; fi
}

# The name check run.sh applies to modules, groups and sources.
SETUP_NAME_RE='^[a-z0-9][a-z0-9-]*$'

# What an egress group opens: its hosts. What a skill source is: its URL.
# "(yours)" for a file in your directory.
setup_describe() {  # <egress|skill> <file>
  local text
  if [[ "$1" == egress ]]; then
    text="$(sed 's/#.*//' "$2" | awk 'NF { print $1 }' | paste -sd' ')"
  else
    text="$(source_value "$2" URL)"
  fi
  (( ${#text} > 60 )) && text="${text:0:60}" && text="${text% *} ..."
  [[ "$2" == "$AB_HOME_DIR"/* ]] && text="(yours) $text"
  echo "$text"
}

# Names of <dir>/*.conf or <dir>/*/mcp.sh over all <dirs>, sorted, once each.
setup_names() {  # <conf|mcp> <dirs...>
  local kind="$1" d f
  shift
  for d in "$@"; do
    if [[ "$kind" == mcp ]]; then
      for f in "$d"/*/mcp.sh; do [[ -f "$f" ]] && basename "$(dirname "$f")"; done
    else
      for f in "$d"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done
    fi
  done | sort -u
}

setup_file_of() {  # <name> <dirs...>: the first <dir>/<name>.conf
  local name="$1" d
  shift
  for d in "$@"; do [[ -f "$d/$name.conf" ]] && { echo "$d/$name.conf"; return; }; done
}

# A module's description, settings, required settings, secrets and secret
# help (entries split by a tab), read in a subshell, so that a broken module
# of yours does not end the menu. 1 if it cannot be read.
setup_module_info() {  # <name>: five lines
  if [[ -z "${SETUP_INFO[$1]+x}" ]]; then
    SETUP_INFO[$1]="$(
      mcp_load "$1" >/dev/null 2>&1 || exit 1
      echo "${MCP_DESCRIPTION:-}"
      echo "${MCP_CONFIG[*]-}"
      echo "${MCP_REQUIRED_CONFIG[*]-}"
      echo "${MCP_SECRETS[*]-}"
      (IFS=$'\t'; echo "${MCP_SECRET_HELP[*]-}")
    )" 2>/dev/null || SETUP_INFO[$1]="!"
  fi
  [[ "${SETUP_INFO[$1]}" != "!" ]] && echo "${SETUP_INFO[$1]}"
}

# The module's line <n> (2 settings, 3 required, 4 secrets, 5 help).
setup_module_line() {  # <name> <n>
  setup_module_info "$1" | sed -n "${2}p"
}

setup_secret_help() {  # <module> <secret>: what to type, from MCP_SECRET_HELP
  local h
  while IFS= read -r h; do
    [[ "$h" == "$2: "* ]] && { echo "${h#"$2: "}"; return; }
  done < <(setup_module_line "$1" 5 | tr '\t' '\n')
  echo "see the module's README section"
}

# The value of secret <secret> for what was typed: the module's
# mcp_secret_value, or as typed.
setup_secret_value() {  # <module> <secret> <typed>
  (
    mcp_load "$1" >/dev/null 2>&1 || exit 1
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

# Whether config.env must hold <value> in quotes: with " #" (a comment to
# the parser), or quoted itself (the parser would take the quotes off).
setup_needs_quotes() {  # <value>
  [[ "$1" == *" #"* || "$1" == *$'\t#'* || "$1" =~ ^\".*\"$ || "$1" =~ ^\'.*\'$ ]]
}

# A value config.env can hold: one line; in quotes, not both kinds of quote.
setup_valid_value() {  # <value>
  [[ "$1" != *$'\n'* ]] || return 1
  if setup_needs_quotes "$1"; then
    [[ "$1" != *\"* || "$1" != *\'* ]] || return 1
  fi
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
    if ! setup_valid_value "$reply"; then echo "  not a value config.env can hold"; continue; fi
    if [[ "$key" == AB_UPDATE_EVERY && ! "$reply" =~ ^[0-9]+$ ]]; then echo "  a number of seconds"; continue; fi
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
  local keys req k s
  if ! setup_module_info "$1" >/dev/null; then echo "  module $1 cannot be read"; return; fi
  keys="$(setup_module_line "$1" 2)"; req="$(setup_module_line "$1" 3)"
  for k in $keys; do
    if in_list "$k" "$req"; then setup_ask_value "$k" "setting of $1" required
    else setup_ask_value "$k" "setting of $1, optional"; fi
  done
  for s in $(setup_module_line "$1" 4); do setup_ask_secret "$s" "$1" ${2:+replace}; done
}

# Forgets the pending settings and secrets of module <name>, turned off
# before they were saved.
setup_module_forget() {  # <name>
  local k
  for k in $(setup_module_line "$1" 2); do unset "SETUP_NEW[$k]"; done
  for k in $(setup_module_line "$1" 4); do unset "SETUP_SECRETS[$k]"; done
}

# The status line under module <name>, number <n>: its settings, whether
# its secrets are there. Empty for a module with neither.
setup_module_status() {  # <name> <n>
  local keys req secrets k v out=""
  keys="$(setup_module_line "$1" 2)"; req="$(setup_module_line "$1" 3)"; secrets="$(setup_module_line "$1" 4)"
  [[ -n "$keys$secrets" ]] || return 0
  for k in $keys; do
    v="$(setup_get "$k")"
    if [[ -n "${!k+x}" ]]; then out+=" · $k=${!k} (environment)"
    elif [[ -n "$v" ]]; then out+=" · $k=$v"
    elif in_list "$k" "$req"; then out+=" · $k NEEDED"
    else out+=" · $k (default)"; fi
  done
  for k in $secrets; do
    if [[ -n "${SETUP_SECRETS[$k]+x}" ]]; then out+=" · secret $k: new"
    elif setup_has_secret "$k"; then out+=" · secret $k: stored"
    else out+=" · secret $k: MISSING"; fi
  done
  echo "${out# · } · e $2"
}

# The menu, one entry per line: "<kind> <key or name>"; printed by
# setup_show, acted on by setup_act.
setup_entries() {
  local n
  # Line by line: a file name with a space or * stays one name.
  while IFS= read -r n; do [[ "$n" == context7 ]] || echo "mcp $n"; done < <(setup_names mcp "${MCP_DIRS[@]}")
  while IFS= read -r n; do echo "skill $n"; done < <(setup_names conf "${SKILLS_SOURCE_DIRS[@]}")
  while IFS= read -r n; do echo "egress $n"; done < <(setup_names conf "${EGRESS_DIRS[@]}")
  for n in "${SETUP_OTHER[@]}"; do echo "other ${n%% *}"; done
}

setup_show() {
  local i=0 kind name section="" mcp skills egress mark text status entry key env="" keys=()
  mcp="$(setup_get AB_MCP)"; mcp="${mcp//,/ }"
  skills="$(setup_get AB_SKILLS)"; skills="${skills//,/ }"
  egress="$(setup_get AB_EGRESS "$EGRESS_DEFAULT")"; egress="${egress//,/ }"
  echo
  echo -n "agentbox setup: $CONFIG_FILE"
  (( ${#SETUP_NEW[@]} + ${#SETUP_SECRETS[@]} )) && echo -n " (changed, not saved)"
  echo
  while read -r kind name; do
    i=$((i + 1))
    status=""
    if [[ "$kind" != "$section" ]]; then
      section="$kind"
      case "$kind" in
        mcp) echo "MCP servers (AB_MCP; context7 is always on)" ;;
        skill) echo "Skill sources (AB_SKILLS)" ;;
        egress) echo "Hosts the agent may reach (AB_EGRESS)" ;;
        other) echo "Other settings" ;;
      esac
    fi
    case "$kind" in
      mcp) in_list "$name" "$mcp" && mark="[x]" || mark="[ ]"
           if text="$(setup_module_line "$name" 1)" && setup_module_info "$name" >/dev/null; then
             [[ -f "$USER_MCP_DIR/$name/mcp.sh" ]] && text="(yours) $text"
             status="$(setup_module_status "$name" "$i")"
             keys+=($(setup_module_line "$name" 2))
           else
             text="(cannot be read)"
           fi ;;
      skill) in_list "$name" "$skills" && mark="[x]" || mark="[ ]"
             text="$(setup_describe skill "$(setup_file_of "$name" "${SKILLS_SOURCE_DIRS[@]}")")" ;;
      egress) in_list "$name" "$egress" && mark="[x]" || mark="[ ]"
              text="$(setup_describe egress "$(setup_file_of "$name" "${EGRESS_DIRS[@]}")")" ;;
      other)
        for entry in "${SETUP_OTHER[@]}"; do [[ "${entry%% *}" == "$name" ]] && break; done
        entry="${entry#* }"
        if [[ "${entry%% *}" == flag ]]; then
          [[ "$(setup_get "$name")" == 1 ]] && mark="[x]" || mark="[ ]"
          text="$name: ${entry#* }"
        else
          mark="   "
          text="$name=$(setup_get "$name")  (${entry#* })"
        fi
        ;;
    esac
    if [[ "$kind" != other && ! "$name" =~ $SETUP_NAME_RE ]]; then
      mark="[-]"; text="cannot be used: names are a-z, 0-9 and - only"; status=""
    fi
    printf '%3d %s %-14s %s\n' "$i" "$mark" "$([[ "$kind" == other ]] || echo "$name")" "$text"
    [[ -n "$status" ]] && printf '        %s\n' "$status"
  done < <(setup_entries)
  for key in "${CONFIG_KEYS[@]}" ${keys[@]+"${keys[@]}"}; do [[ -n "${!key+x}" ]] && env+=" $key"; done
  [[ -n "$env" ]] && echo "Note: set in your environment, which wins over config.env:$env"
  echo "number: toggle or edit; e <number>: settings and secrets of a module; s: save; q: quit"
}

setup_act() {  # <number> [e]
  local kind name list entry
  kind=""; name=""
  read -r kind name < <(setup_entries | sed -n "${1}p")
  [[ -n "$kind" ]] || { echo "no entry $1"; return; }
  if [[ -n "${2:-}" && "$kind" != mcp ]]; then echo "  e is for MCP modules; $1 is not one"; return; fi
  if [[ "$kind" != other && ! "$name" =~ $SETUP_NAME_RE ]]; then
    echo "  '$name' cannot be used: run.sh takes names of a-z, 0-9 and - only; rename its file"; return
  fi
  case "$kind" in
    mcp)
      if [[ -n "${2:-}" ]]; then setup_module_settings "$name" all; return; fi
      list="$(setup_get AB_MCP)"; list="${list//,/ }"
      # One that cannot be read can only go: run.sh would stop on it.
      if ! in_list "$name" "$list" && ! setup_module_info "$name" >/dev/null; then
        echo "  module $name cannot be read (run agentbox to see why); not turned on"; return
      fi
      setup_record_list AB_MCP "$(list_toggle "$name" "$list")"
      if in_list "$name" "$list"; then setup_module_forget "$name"; else setup_module_settings "$name"; fi ;;
    skill)
      list="$(setup_get AB_SKILLS)"; list="${list//,/ }"
      setup_record_list AB_SKILLS "$(list_toggle "$name" "$list")" ;;
    egress)
      list="$(setup_get AB_EGRESS "$EGRESS_DEFAULT")"; list="${list//,/ }"
      setup_record_list AB_EGRESS "$(list_toggle "$name" "$list")" "$EGRESS_DEFAULT"
      if [[ "$name" == anthropic ]] && in_list anthropic "$list"; then
        echo "  note: Claude Code does not start without anthropic"
      fi ;;
    other)
      for entry in "${SETUP_OTHER[@]}"; do [[ "${entry%% *}" == "$name" ]] && break; done
      entry="${entry#* }"
      if [[ "${entry%% *}" == flag ]]; then
        if [[ "$(setup_get "$name")" == 1 ]]; then setup_record "$name" unset; else setup_record "$name" "set 1"; fi
      else
        setup_ask_value "$name" "${entry#* }"
      fi ;;
  esac
}

# Applies SETUP_NEW to <file>: replaces a key's first active line (keeping
# a comment after its value), else uncomments a "#KEY=" line, else
# appends; "unset" comments the active lines out. Values are read from the
# environment (awk -v would interpret backslashes). 1 on any failure.
setup_apply() {  # <in> <out>
  local key c val
  cp -- "$1" "$2" || return 1
  for key in "${!SETUP_NEW[@]}"; do
    c="${SETUP_NEW[$key]}"
    val=""
    if [[ "$c" == set* ]]; then
      val="${c#set }"
      setup_needs_quotes "$val" && { [[ "$val" == *\"* ]] && val="'$val'" || val="\"$val\""; }
    fi
    SETUP_KEY="$key" SETUP_VAL="$val" SETUP_MODE="${c%% *}" awk '
      BEGIN { k = ENVIRON["SETUP_KEY"]; v = ENVIRON["SETUP_VAL"]; mode = ENVIRON["SETUP_MODE"] }
      # The comment after the value of a KEY=value line, with its spaces:
      # after the closing quote of a quoted value, else from " #" on.
      function comment(line,   val, q, rest) {
        val = substr(line, index(line, "=") + 1)
        q = substr(val, 1, 1)
        if (q == "\"" || q == "\047") {
          rest = substr(val, 2)
          if (!index(rest, q)) return ""
          rest = substr(rest, index(rest, q) + 1)
          return (rest ~ /^[ \t]+#/) ? rest : ""
        }
        if (match(val, /[ \t]+#.*$/)) return substr(val, RSTART)
        return ""
      }
      { lines[++n] = $0 }
      END {
        for (i = 1; i <= n; i++) {
          l = lines[i]; sub(/^[ \t]+/, "", l); sub(/^export /, "", l)
          if (index(l, k "=") == 1) active[i] = 1
          else if (!hint && l ~ "^#[ \t]*" k "=") hint = i
          if (active[i] && !first) first = i
        }
        for (i = 1; i <= n; i++) {
          if (mode == "set" && i == first) { print k "=" v comment(lines[i]); continue }
          if (active[i] && (mode == "unset" || i != first)) { print "#" lines[i]; continue }
          print lines[i]
          if (mode == "set" && !first && i == hint) print k "=" v
        }
        if (mode == "set" && !first && !hint) print k "=" v
      }' "$2" > "$2.new" && mv -f -- "$2.new" "$2" || { rm -f -- "$2.new"; return 1; }
  done
}

# Writes the pending changes. A config.env that is a link stays one: the
# file it points to is edited. On a failure nothing is cleared, so "s" can
# be tried again.
setup_save() {
  local target src tmp name failed=""
  if (( ${#SETUP_NEW[@]} + ${#SETUP_SECRETS[@]} == 0 )); then
    echo "agentbox: nothing to save"
    return 0
  fi
  if (( ${#SETUP_NEW[@]} )); then
    target="$(realpath -m -- "$CONFIG_FILE")"
    # No config.env yet: made from the example, in place only once complete.
    src="$target"
    [[ -f "$target" ]] || src="$SCRIPT_DIR/config.env.example"
    if mkdir -p "$(dirname "$target")" && tmp="$(mktemp "$target.XXXXXX")" && setup_apply "$src" "$tmp"; then
      if [[ "$src" != "$target" ]]; then
        chmod 600 -- "$tmp" && mv -f -- "$tmp" "$target" && echo "agentbox: saved $CONFIG_FILE, made from the example" || failed=1
      elif cmp -s "$target" "$tmp"; then
        rm -f -- "$tmp"
      elif cp -p -- "$target" "$target.bak" && chmod --reference="$target" -- "$tmp" && mv -f -- "$tmp" "$target"; then
        echo "agentbox: saved $CONFIG_FILE (the previous one is $target.bak)"
      else
        failed=1
      fi
    else
      failed=1
    fi
    [[ -n "${tmp:-}" ]] && rm -f -- "$tmp"
    if [[ -n "$failed" ]]; then
      echo "error: could not write $CONFIG_FILE; nothing saved" >&2
      return 1
    fi
  fi
  for name in "${!SETUP_SECRETS[@]}"; do
    if printf '%s' "${SETUP_SECRETS[$name]}" | secret_store "$name"; then
      echo "agentbox: stored the Podman secret $name"
      unset "SETUP_SECRETS[$name]"
    else
      echo "error: could not store the Podman secret $name" >&2
      failed=1
    fi
  done
  SETUP_NEW=(); SETUP_FILE=(); SETUP_HAS=()
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
