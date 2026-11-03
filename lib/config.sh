# Configuration file: KEY=VALUE lines, optional quotes. # starts a comment
# at the start of a line or after a space (KEY=value # note); a # inside a
# value (a URL fragment) stays.
# Parsed, not sourced, so it cannot run code, and only known keys are
# accepted: agentbox's own (CONFIG_KEYS) and those the enabled MCP modules
# declare. A variable already set in the environment wins over the file.
#
# Two passes: the first reads agentbox's keys, including AB_MCP; the enabled
# modules then add their keys (GRAFANA_URL, ...), and the second pass reads
# those, warning about anything still unknown.

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

# Names of MCP modules, egress groups and skill sources (run.sh and
# agentbox setup), and of a module's servers.
AB_NAME_RE='^[a-z0-9][a-z0-9-]*$'

# The first <dir>/<name>.conf over <dirs>: yours before the shared ones.
conf_find() {  # <name> <dirs...>
  local name="$1" d
  shift
  for d in "$@"; do [[ -f "$d/$name.conf" ]] && { printf '%s\n' "$d/$name.conf"; return 0; }; done
  return 1
}

CONFIG_KEYS=(AB_MCP AB_EGRESS AB_FORWARD AB_SKILLS AB_SKILLS_DIR AB_UPDATE_EVERY AB_SERVICES AB_ENV_DIR AB_CHECK_UPDATES AB_GRAPHIFY_EXTRAS AB_TRIVY
  AB_PYTHON_VERSIONS AB_GO_VERSION AB_GOLANGCI_LINT_VERSION AB_WARNINGS_ASK)
CONFIG_FILE="${AB_CONFIG:-$USER_CONFIG}"

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
    if [[ "$line" != *=* ]]; then
      [[ "$warn" == 1 ]] && ab_warn "$file:$n: not KEY=VALUE, ignored"
      continue
    fi
    key="${line%%=*}"; val="${line#*=}"
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

config_first_pass() {
  if [[ -f "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE" 0 "${CONFIG_KEYS[@]}"
  elif [[ -n "${AB_CONFIG:-}" ]]; then
    echo "error: AB_CONFIG=$AB_CONFIG does not exist" >&2
    exit 2
  fi
}

config_second_pass() {  # <module keys...>
  if [[ -f "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE" 1 "${CONFIG_KEYS[@]}" "$@"
  fi
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
