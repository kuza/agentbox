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
# The settings file of v0.1.x: the conversion reads it, and agentbox setup
# still edits it.
CONFIG_OLD_FILE="${CONFIG_FILE%.toml}.env"

# Reads the settings in <file> (TOML, the kind config) into variables of
# the same names, for <keys> only. A variable in the environment wins over
# the file. For a key of CONFIG_LIST_KEYS, this function splits the value at
# spaces and commas, and joins the items with a space. With <warn> 1, a key of the file that is not in <keys> or <quiet
# keys> gets a warning. Returns the status of toml_load. This is the only
# place that reads the settings from the environment.
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
    [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "${values[$key]}"
  done
  for key in "${CONFIG_LIST_KEYS[@]}"; do
    if [[ "$keys" == *" $key "* && -n "${!key:-}" ]]; then
      read -ra items <<< "${!key//,/ }"
      printf -v "$key" '%s' "${items[*]}"
    fi
  done
}

# <file> of v0.1.x: KEY=VALUE lines, optional quotes. # starts a comment at
# the start of a line or after a space (KEY=value # note); a # inside a
# value (a URL fragment) stays. Only agentbox setup reads this form, until
# it edits config.toml.
load_config() {  # <file> <warn about unknown keys: 0|1> <allowed keys...>
  local file="$1" warn="$2" line key val n=0
  shift 2
  local allowed=" $* "
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"            # trim leading space
    line="${line%"${line##*[![:space:]]}"}"            # trim trailing space
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    # A key must be a name: "A B=x" would match two allowed keys in a row,
    # and ${!key} then stops the start.
    if [[ "$line" != *=* || ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      [[ "$warn" == 1 ]] && ab_warn "$file:$n: not KEY=VALUE, ignored"
      continue
    fi
    if [[ "$val" =~ ^\"([^\"]*)\"([[:space:]]+#.*)?$ || "$val" =~ ^\'([^\']*)\'([[:space:]]+#.*)?$ ]]; then
      val="${BASH_REMATCH[1]}"
    else
      val="${val%%[[:space:]]#*}"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    if [[ "$allowed" != *" $key "* ]]; then
      [[ "$warn" == 1 ]] && ab_warn "$file:$n: unknown key '$key', ignored"
      continue
    fi
    if [[ -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$val"
    fi
  done < "$file"
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
