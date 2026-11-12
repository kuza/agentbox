# lib/toml.sh reads the settings in config.toml. It does not source the
# file, so the file cannot run code. Only known keys are read: the keys of agentbox
# (CONFIG_KEYS) and the keys that the enabled MCP modules declare. A
# variable in the environment wins over the file (settings_load).

# Warnings of a start: printed, and kept in AB_WARNINGS_FILE (made by
# run.sh; a file, so that warnings from subshells count too) for
# warnings_review, which names them again before the session: by then they
# have scrolled away under the agent's screen.
AB_WARNINGS_FILE=""
ab_warn() {  # <message...>
  echo "agentbox: warning: $*" >&2
  if [[ -n "$AB_WARNINGS_FILE" ]]; then printf '%s\n' "$*" >> "$AB_WARNINGS_FILE"; fi
}

# An error, printed now. Inside an MCP module's start (lib/mcp.sh) also kept
# as the reason the warning about that module gives.
AB_MODULE_ERRORS=""
ab_error() {  # <message...>
  echo "error: $*" >&2
  if [[ -n "$AB_MODULE_ERRORS" ]]; then printf '%s\n' "$*" >> "$AB_MODULE_ERRORS"; fi
}

# The reason of a module's failed start, not printed: for an error that is
# already on the terminal in full.
ab_reason() {  # <message...>
  if [[ -n "$AB_MODULE_ERRORS" ]]; then printf '%s\n' "$*" >> "$AB_MODULE_ERRORS"; fi
}

# At a terminal, the warnings of this start again, right before the
# session, which starts on Enter and not on "n". No question without a
# terminal, with AB_WARNINGS_ASK=0, for an agent run with -p or --print, or
# a shell given a command: they start, warned.
warnings_review() {  # <the session's arguments...>
  local reply="" w a ask=1
  rm -f -- "$AB_WARNINGS_FILE.err"
  [[ -s "$AB_WARNINGS_FILE" ]] || { rm -f -- "$AB_WARNINGS_FILE"; return 0; }
  [[ -t 0 && -t 1 && "${AB_WARNINGS_ASK:-1}" != 0 ]] || ask=""
  [[ "$AGENT" == shell && $# -gt 0 ]] && ask=""
  for a in "$@"; do [[ "$a" == -p || "$a" == --print ]] && ask=""; done
  if [[ -n "$ask" ]]; then
    echo "agentbox: this start warned:" >&2
    while IFS= read -r w; do echo "  - $w" >&2; done < "$AB_WARNINGS_FILE"
    read -r -p "agentbox: start the session? [Y/n] " reply || reply=n
    if [[ "$reply" == [nN]* ]]; then
      rm -f -- "$AB_WARNINGS_FILE"
      echo "agentbox: not started" >&2
      exit 1
    fi
  fi
  rm -f -- "$AB_WARNINGS_FILE"
}

# The first <dir>/<name>.<extension> over <dirs>: yours before the shared
# ones.
conf_find() {  # <name> <extension> <dirs...>
  local name="$1" ext="$2" d
  shift 2
  for d in "$@"; do [[ -f "$d/$name.$ext" ]] && { printf '%s\n' "$d/$name.$ext"; return 0; }; done
  return 1
}

CONFIG_KEYS=(AB_MCP AB_EGRESS AB_FORWARD AB_SKILLS AB_SKILLS_DIR AB_PI_EXTENSIONS AB_UPDATE_EVERY AB_SERVICES AB_ENV_DIR AB_CHECK_UPDATES AB_GRAPHIFY_EXTRAS AB_TRIVY
  AB_PYTHON_VERSIONS AB_GO_VERSION AB_GOLANGCI_LINT_VERSION AB_WARNINGS_ASK)
# The keys of CONFIG_KEYS that are lists. lib/toml-schema/config.toml gives
# them the type list.
CONFIG_LIST_KEYS=(AB_MCP AB_EGRESS AB_SKILLS AB_PI_EXTENSIONS AB_SERVICES AB_FORWARD AB_PYTHON_VERSIONS)
# The settings file: config.toml in AB_HOME, or the file of AB_CONFIG. When
# AB_CONFIG names a .env file of v0.1.x, the TOML file next to it
# (lib/convert.sh writes it).
CONFIG_FILE="${AB_CONFIG:-$USER_CONFIG}"
if [[ "$CONFIG_FILE" == *.env ]]; then CONFIG_FILE="${CONFIG_FILE%.env}.toml"; fi
# The settings file of v0.1.x: the conversion reads it.
CONFIG_OLD_FILE="${CONFIG_FILE%.toml}.env"

# Reads the settings in <file> (TOML, the kind config) into variables of
# the same names, for <keys> only. A variable in the environment wins over
# the file. For a key of CONFIG_LIST_KEYS, this function splits the value at
# spaces and commas, and joins the items with a space. With <warn> 1, a key of the file that is not in <keys> or <quiet
# keys> gets a warning. Returns the status of toml_load. This is the only
# place that reads the settings from the environment. SETTING_AT[<key>]
# keeps the place of a value, for the message of a failed check:
# "<file>:<line>", or "environment" for a value from the environment.
declare -gA SETTING_AT=()
settings_load() {  # <file> <warn: 0|1> <keys...> [-- <quiet keys...>]
  local file="$1" warn="$2" key items keys=" "
  local -A values=() lines=()
  shift 2
  while (( $# )) && [[ "$1" != -- ]]; do keys+="$1 "; shift; done
  local quiet=" ${*:2} "
  toml_load config "$file" values lines || return
  for key in "${!values[@]}"; do
    if [[ "$keys" != *" $key "* ]]; then
      [[ "$warn" == 1 && "$quiet" != *" $key "* ]] && ab_warn "$file:${lines[$key]%% *}: unknown key '$key', ignored (unknown-key)"
      continue
    fi
    if [[ -n "${!key+x}" ]]; then
      SETTING_AT[$key]="${SETTING_AT[$key]:-environment}"
    else
      printf -v "$key" '%s' "${values[$key]}"
      SETTING_AT[$key]="$file:${lines[$key]%% *}"
    fi
  done
  for key in "${CONFIG_LIST_KEYS[@]}"; do
    if [[ "$keys" == *" $key "* && -n "${!key:-}" ]]; then
      read -ra items <<< "${!key//,/ }"
      printf -v "$key" '%s' "${items[*]}"
    fi
  done
}

# Sets <key> in <file> (TOML, the kind config) to <value>, as bash gives
# it (settings_load). With no <value>, it puts a # before the line of the
# key (the key is then not set).
# The other lines and the comment after the old value stay. A key that is
# not set replaces its first "#KEY =" line (from config.toml.example), or
# goes at the end. Give the real file: a link becomes a plain file.
#
# The type comes from lib/toml-schema/config.toml. A list is an array of
# the words of <value>, split at spaces and commas. An int is digits. A bool
# is true for 1. For 0, a bool that is on by default (AB_CHECK_UPDATES,
# AB_WARNINGS_ASK) is false; another bool is unset. A key outside the schema
# is a setting of a module. It keeps the form of its line in the file or in
# the example: an array, a number, or a string.
#
# It refuses a value on more than one line, or a line that it does not
# understand, and says why. It writes a temp file, and moves it over <file>
# only when toml_load can read it. 1 on any failure. Needs lib/toml.sh.
config_set() {  # <file> <key> [<value>]
  # CONFIG_SET_NAME: the name of the file in messages, when <file> is a
  # work copy (setup_save).
  local file="$1" key="$2" value="${3:-}" del=0 type text="" old="" i at=0 end=0 tmp form="" shown="${CONFIG_SET_NAME:-$1}"
  local -a items=() rows=()
  local -A values=() lines=()
  (( $# < 3 )) && del=1
  toml_load config "$file" values lines || { echo "error: $shown: cannot change $key (see the error above)" >&2; return 1; }
  type="$(awk -v k="[$key]" '$0 == k { f = 1; next } f && /^type *=/ { gsub(/^type *= *"|"$/, ""); print; exit }' "$SCRIPT_DIR/lib/toml-schema/config.toml")"
  if [[ "$type" == bool && "$value" == 0 && " AB_CHECK_UPDATES AB_WARNINGS_ASK " != *" $key "* ]]; then del=1; fi
  mapfile -t rows < "$file"
  # The line of the key, or its first "#KEY =" line.
  if [[ -n "${lines[$key]+x}" ]]; then
    read -r at end <<< "${lines[$key]}"
    form="${rows[at - 1]#*=}"
  else
    for i in "${!rows[@]}"; do
      # A line of the example, such as "#AB_TRIVY = true": the value
      # starts as a TOML value does. A comment in words does not count.
      [[ "${rows[i]}" =~ ^#[[:space:]]*${key}[[:space:]]*=[[:space:]]*([\"\'\[0-9]|true|false) ]] \
        && { at=$((i + 1)); form="${rows[i]#*=}"; break; }
    done
  fi
  # A setting of a module keeps the form of that line.
  if [[ -z "$type" ]]; then
    form="${form#"${form%%[![:space:]]*}"}"
    if [[ "$form" == "["* ]]; then type=list
    elif [[ "$form" =~ ^[0-9]+([[:space:]]|$) && "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then type=int
    fi
  fi
  if (( ! del )); then
    case "$type" in
      list) read -ra items <<< "${value//,/ }"
            for i in ${items[@]+"${items[@]}"}; do text+="${text:+, }$(config_string "$i")"; done
            text="[$text]" ;;
      int) [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "error: $key: '$value' is not a whole number" >&2; return 1; }
           text="$value" ;;
      bool) case "$value" in 1) text=true ;; 0) text=false ;; *) echo "error: $key: '$value' is not 1 or 0" >&2; return 1 ;; esac ;;
      *) text="$(config_string "$value")" ;;
    esac
    text="$key = $text"
  fi
  if [[ -n "${lines[$key]+x}" ]]; then
    if (( at != end )); then
      echo "error: $shown:$at: the value of $key is on more than one line (to line $end). Change it in the file." >&2
      return 1
    fi
    old="${rows[at - 1]}"
    if [[ ! "$old" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
      echo "error: $shown:$at: agentbox does not understand this line of $key. Change it in the file." >&2
      return 1
    fi
    if (( del )); then text="#$old"; else text+="$(config_comment "${old#*=}")"; fi
  elif (( del )); then
    return 0
  fi
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  {
    for i in "${!rows[@]}"; do
      if (( i + 1 == at )); then printf '%s\n' "$text"; else printf '%s\n' "${rows[i]}"; fi
    done
    (( at )) || printf '%s\n' "$text"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  # toml_load must read the new file: a bug here must not break your settings.
  if ! toml_load config "$tmp" values >/dev/null || ! chmod --reference="$file" -- "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    echo "error: $shown: could not set $key" >&2
    return 1
  fi
}

# <value> as a TOML basic string: in double quotes, with \ and " escaped.
config_string() {  # <value>
  local v="${1//\\/\\\\}"
  printf '"%s"' "${v//\"/\\\"}"
}

# The comment after a value, with the spaces before it: the text from the
# first # outside a string. <rest> is the text after the = of a line that
# toml_load has read, so its strings are closed.
config_comment() {  # <rest>
  local s="$1" i c q=""
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      if [[ "$q" == '"' && "$c" == '\' ]]; then i=$((i + 1)); elif [[ "$c" == "$q" ]]; then q=""; fi
    elif [[ "$c" == '"' || "$c" == "'" ]]; then
      q="$c"
    elif [[ "$c" == '#' ]]; then
      s="${s:0:i}"
      printf '%s#%s' "${s##*[![:space:]]}" "${1:i+1}"
      return
    fi
  done
}

# The first pass reads the keys of agentbox, AB_MCP too. The enabled modules
# then add their keys (GRAFANA_URL, ...), and the second pass reads them.
# It warns about a key that no module has. Needs lib/toml.sh and
# lib/convert.sh.
config_first_pass() {
  if convert_pending "$CONFIG_OLD_FILE"; then
    echo "error: $CONFIG_OLD_FILE was not converted to TOML (see the warning above)" >&2
    exit 2
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    settings_load "$CONFIG_FILE" 0 "${CONFIG_KEYS[@]}" || exit 2
  elif [[ -n "${AB_CONFIG:-}" ]]; then
    echo "error: AB_CONFIG: $CONFIG_FILE does not exist" >&2
    exit 2
  fi
  return 0
}

config_second_pass() {  # <module keys...> -- <quiet keys: the keys of the modules that are not enabled>
  if [[ -f "$CONFIG_FILE" ]]; then
    settings_load "$CONFIG_FILE" 1 "${CONFIG_KEYS[@]}" "$@" || exit 2
  fi
  return 0
}

# Constants and defaults.
IMAGE="localhost/agentbox"
# Built here from Containerfile.squid (Debian), not pulled.
IMG_SQUID="localhost/agentbox-squid"
# Pulled before agentbox built its own squid; removed once, when an
# ab-egress still on it is replaced (egress_start), never otherwise: it may
# be yours too.
IMG_SQUID_OLD="docker.io/ubuntu/squid:latest"
IMG_NGINX="docker.io/library/nginx:alpine"
# Map the host user to uid/gid 1000 (the "node" user in the image),
# so files written in the repo are owned by you on the host.
USERNS="keep-id:uid=1000,gid=1000"
