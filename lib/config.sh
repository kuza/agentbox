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

CONFIG_KEYS=(AB_MCP AB_EGRESS AB_FORWARD AB_SKILLS AB_SKILLS_DIR AB_UPDATE_EVERY AB_SERVICES AB_ENV_DIR AB_CHECK_UPDATES AB_GRAPHIFY_EXTRAS AB_TRIVY
  AB_PYTHON_VERSIONS AB_GO_VERSION AB_GOLANGCI_LINT_VERSION)
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
      [[ "$warn" == 1 ]] && echo "agentbox: warning: $file:$n: not KEY=VALUE, ignored" >&2
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
      [[ "$warn" == 1 ]] && echo "agentbox: warning: $file:$n: unknown key '$key', ignored" >&2
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
IMG_SQUID="docker.io/ubuntu/squid:latest"
IMG_NGINX="docker.io/library/nginx:alpine"
# Map the host user to uid/gid 1000 (the "node" user in the image),
# so files written in the repo are owned by you on the host.
USERNS="keep-id:uid=1000,gid=1000"
