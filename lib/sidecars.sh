# Sidecars. Started once and reused across sessions, so several sessions can
# run in parallel. A sidecar is recreated when what it is started with
# changes: its podman run arguments (settings, labels, image tag), the
# content of the files it mounts, or the Podman secrets it holds (their IDs).
# Changes nobody can see from here, such as a server that restarted on its
# own and got a new address, need AB_RESTART=1.

SIDECARS_WANTED=()

# What a sidecar or host service is started with, as a short hash: the
# arguments, and the content of each file an argument names (a path, or the
# source of a "src:dst" mount).
config_hash() {  # <arguments...>
  local arg src
  {
    printf '%s\n' "$@"
    for arg in "$@"; do
      src="${arg%%:*}"
      if [[ "$src" == /* && -f "$src" ]]; then cat -- "$src"; fi
    done
  } | sha256sum | cut -c1-16
}

# The IDs of all Podman secrets, read by one podman call (secret_ids_load).
# A secret agentbox makes goes in with its ID; one stored in a pipeline
# (printf ... | secret_store, which runs in a subshell) does not reach this
# list, so the caller reads it again (secret_ids_reload).
declare -A SECRET_IDS=()
SECRET_IDS_LOADED=""

# A failed listing stops the start: taken for "no secrets", it would report
# every secret missing and recreate every sidecar that holds one.
secret_ids_load() {
  local name id out
  [[ -n "$SECRET_IDS_LOADED" ]] && return 0
  if ! out="$(podman secret ls --format '{{.Name}} {{.ID}}')"; then
    ab_error "cannot list the Podman secrets (podman secret ls failed)"
    exit 1
  fi
  SECRET_IDS=()
  while read -r name id; do
    [[ -n "$name" ]] && SECRET_IDS["$name"]="$id"
  done <<<"$out"
  SECRET_IDS_LOADED=1
}

secret_ids_reload() {
  SECRET_IDS_LOADED=""
  secret_ids_load
}

# A secret agentbox just made, added to the list with the ID podman secret
# create printed.
secret_ids_add() {  # <secret name> <ID>
  SECRET_IDS["$1"]="$2"
}

secret_exists() {  # <secret name>: 0 if it exists, from the IDs read once
  secret_ids_load
  [[ -n "${SECRET_IDS[$1]+x}" ]]
}

# The IDs of the Podman secrets in <podman run arguments>: a secret made
# anew (a renewed token through agentbox setup) has a new ID, and the
# sidecar holding the old value is recreated. Needs secret_ids_load first.
secret_ids() {  # <podman run arguments...>
  local prev="" arg name
  for arg in "$@"; do
    name=""
    if [[ "$prev" == --secret ]]; then name="${arg%%,*}"
    elif [[ "$arg" == --secret=* ]]; then name="${arg#--secret=}"; name="${name%%,*}"
    fi
    if [[ -n "$name" ]]; then
      printf 'secret %s %s\n' "$name" "${SECRET_IDS[$name]:-}"
    fi
    prev="$arg"
  done
}

# The MCP module whose mcp_start runs now (lib/mcp.sh): its sidecars, their
# copies in the cache and its host services are marked as its own, and
# found by that mark, never by a name that only starts like it.
AB_CURRENT_MODULE=""

start_sidecar() {  # <name> <podman run arguments...>
  local name="$1" hash
  shift
  SIDECARS_WANTED+=("$name")
  [[ -n "$AB_CURRENT_MODULE" ]] && set -- --label "agentbox.module=$AB_CURRENT_MODULE" "$@"
  secret_ids_load
  hash="$(config_hash "$@" "$(secret_ids "$@")")"
  if [[ "${AB_RESTART:-}" != 1 ]] && sidecar_current "$name" "$hash"; then
    return 0
  fi
  # -v: with the container's anonymous volumes (squid declares some), which
  # would otherwise stay behind on every recreation.
  podman rm -f -v "$name" >/dev/null 2>&1 || true
  podman run -d --replace --name "$name" --label "agentbox.config=$hash" "$@" >/dev/null
}

# 0 if the container runs, was started with <hash> (its agentbox.config
# label), and runs the image its tag names now: a rebuilt squid image
# (image_ensure) or a pulled one keeps the tag, so the arguments alone do not
# show it. Two podman calls.
sidecar_current() {  # <container> <hash>
  local running label tag image id
  IFS='|' read -r running label tag image < <(podman inspect \
    -f '{{.State.Running}}|{{index .Config.Labels "agentbox.config"}}|{{.ImageName}}|{{.Image}}' "$1" 2>/dev/null)
  [[ "$running" == true && "$label" == "$2" && -n "$tag" ]] || return 1
  id="$(podman image inspect -f '{{.Id}}' "$tag" 2>/dev/null)" || return 1
  [[ -n "$id" && "$image" == "$id" ]]
}

# Sidecars with the module that owns them, "<name> <module>" per line; the
# module is empty for ab-egress, ab-llm-* and sidecars made before the mark.
sidecars_list() {
  podman ps -a --format '{{.Names}} {{index .Labels "agentbox.module"}}' \
    | awk '$1 == "ab-egress" || $1 ~ /^ab-mcp-/ || $1 ~ /^ab-llm-/ { print $1, $2 }'
}

# Removes a sidecar now, with its copies in the cache: some hold passwords
# (mcp/dbhub).
sidecar_remove() {  # <container>
  podman rm -f -v "$1" >/dev/null
  rm -rf -- "${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/$1"
}

# 0 if <module> is one this start left out with "keep" (MCP_SKIPPED,
# lib/mcp.sh): what it runs stays for the sessions using it. A sidecar made
# before the mark has no module: its name tells, ab-mcp-<module>[-*]. For a
# module this version does not have (MCP_UNKNOWN), only the mark counts.
skipped_keeps() {  # <owning module, may be empty> <container or unit name>
  local m
  for m in ${MCP_UNKNOWN[@]+"${MCP_UNKNOWN[@]}"}; do
    [[ -n "$1" && "$1" == "$m" ]] && return 0
  done
  for m in ${MCP_SKIPPED[@]+"${MCP_SKIPPED[@]}"}; do
    if [[ -n "$1" ]]; then
      [[ "$1" == "$m" ]] && return 0
    elif [[ "$2" == "ab-mcp-$m" || "$2" == "ab-mcp-$m"-* || "$2" == "agentbox-mcp-$m" || "$2" == "agentbox-mcp-$m"-* ]]; then
      return 0
    fi
  done
  return 1
}

# Removes agentbox sidecars this start did not ask for: those of MCP modules
# no longer in AB_MCP, ab-llm-openai once its key is gone. Sidecars are named
# ab-egress, ab-mcp-* or ab-llm-*. A second agentbox setup with another
# AB_CONFIG on the same host would remove the other's sidecars.
sidecars_cleanup() {
  local name module wanted=" ${SIDECARS_WANTED[*]} "
  while read -r name module; do
    [[ -n "$name" ]] || continue
    [[ "$wanted" == *" $name "* ]] && continue
    skipped_keeps "$module" "$name" && continue
    sidecar_remove "$name" && echo "agentbox: removed $name, no longer enabled" >&2
  done < <(sidecars_list)
}

# Everything of <module>, now: its sidecars and their copies (also copies
# whose container is gone), its host services. For a module whose access
# goes (MCP_TAKE_AWAY, lib/mcp.sh). Found by the mark alone.
module_remove() {  # <module>
  local name module unit d
  while read -r name module; do
    [[ -n "$name" && "$module" == "$1" ]] && sidecar_remove "$name"
  done < <(sidecars_list)
  for d in "${XDG_CACHE_HOME:-$HOME/.cache}"/agentbox/sidecars/*/; do
    [[ "$(cat "$d.module" 2>/dev/null)" == "$1" ]] && rm -rf -- "$d"
  done
  command -v systemctl >/dev/null || return 0
  while read -r unit module; do
    [[ -n "$unit" && "$module" == "$1" ]] && systemctl --user stop "$unit" >/dev/null 2>&1
  done < <(host_units_list)
  return 0
}

# Config files reach sidecars as copies in the cache, never from the repo:
# a sidecar mounts its files with ":Z", a label private to that container,
# which on the repo's own file would lock out agent sessions and git in them
# (README, Troubleshooting). Each container gets a copy of its own.
sidecar_copy() {  # <container> <file>: prints the path of a fresh copy
  sidecar_dir "$1" >/dev/null || return 1
  cache_copy "sidecars/$1" "$2"
}

# The directory of <container>'s copies in the cache, marked with the module
# that owns it (.module), so module_remove finds it with no container left.
sidecar_dir() {  # <container>: prints its path
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/$1"
  mkdir -p "$dir" || { ab_error "cannot write in $dir"; return 1; }
  if [[ -n "$AB_CURRENT_MODULE" ]]; then printf '%s\n' "$AB_CURRENT_MODULE" > "$dir/.module"; fi
  printf '%s\n' "$dir"
}

# A fresh copy of <file> in the cache, under <subdir>: what a container
# mounts instead of a file of agentbox's code. An installed version's files
# are read-only, so podman cannot relabel them for SELinux (":z" and ":Z"
# need write access) and the container could not read them. Written anew and
# renamed into place: a container already running keeps the copy it mounted
# (its bind mount holds the old file), even when sessions share one path.
cache_copy() {  # <subdir> <file> [name]: prints the path of the copy; 1 on failure
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/$1" dst tmp
  dst="$dir/${3:-$(basename "$2")}"
  [[ -f "$2" ]] || { ab_error "$2 is missing"; return 1; }
  mkdir -p "$dir" && tmp="$(mktemp "$dst.XXXXXX")" || { ab_error "cannot write in $dir"; return 1; }
  if ! { cp -- "$2" "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$dst"; }; then
    rm -f -- "$tmp"
    ab_error "cannot copy $2 to $dst"
    return 1
  fi
  printf '%s\n' "$dst"
}

# A file in the cache, under <subdir>, holding <text>, written like
# cache_copy's copies: for a session path that is always mounted, with
# nothing of the user's to put there.
cache_text() {  # <subdir> <name> <text>: prints the path; 1 on failure
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/$1" dst tmp
  dst="$dir/$2"
  mkdir -p "$dir" && tmp="$(mktemp "$dst.XXXXXX")" || { ab_error "cannot write in $dir"; return 1; }
  if ! { printf '%s' "$3" > "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$dst"; }; then
    rm -f -- "$tmp"
    ab_error "cannot write $dst"
    return 1
  fi
  printf '%s\n' "$dst"
}

# Caller tokens: a random secret per sidecar that proves the caller may talk
# to it. Not a credential for the service behind it. Generated once.
ensure_caller_secret() {  # <secret name>
  local id
  secret_exists "$1" && return 0
  id="$(random_token | podman secret create "$1" -)" || return 1
  secret_ids_add "$1" "$id"
  echo "agentbox: created secret $1" >&2
}

random_token() {  # prints 32 random bytes as base64 letters and digits
  head -c 32 /dev/urandom | base64 | tr -d '/+=\n'
}

secret_store() {  # <secret name>: create or replace it with stdin
  local id
  # --replace came with podman 4.7; before, the old secret goes first.
  # Only for an existing secret: podman 4.7-4.9 fail --replace on a new
  # name ("deleting secret : : no secret data with ID").
  if podman secret inspect "$1" >/dev/null 2>&1 \
     && podman secret create --help 2>/dev/null | grep -q -- '--replace'; then
    id="$(podman secret create --replace "$1" -)" || return 1
  else
    podman secret rm "$1" >/dev/null 2>&1 || true
    id="$(podman secret create "$1" -)" || return 1
  fi
  secret_ids_add "$1" "$id"
}

# Host services: programs a module runs on the host itself, not in a
# container (mcp/tabularis: a bridge to a desktop app's stdio MCP server).
# Each is a transient systemd user service named agentbox-*, started with
# systemd-run: no unit file on disk, gone when you log out, started again by
# the next agentbox start. Like a sidecar, it is restarted when its command,
# environment or the content of a file named in its command changes
# (config_hash). A module checks for a systemd user session first
# (host_units_available).

HOST_UNITS_WANTED=()
HOST_UNIT_DESCRIPTION="agentbox host service"

host_units_available() {  # 0 if systemd user services can be started here
  command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1
}

# How systemd runs a host service. A program that keeps failing (a crash
# on start, say) gets three tries a minute, then stays down until the
# next agentbox start.
HOST_UNIT_PROPERTIES=(
  --property=Restart=on-failure --property=RestartSec=5
  --property=StartLimitIntervalSec=60 --property=StartLimitBurst=3
)

start_host_unit() {  # <name> [VAR=value...] -- <command...>
  local name="$1" desc env=()
  shift
  while (( $# )) && [[ "$1" != -- ]]; do env+=("--setenv=$1"); shift; done
  shift
  HOST_UNITS_WANTED+=("$name")
  desc="$HOST_UNIT_DESCRIPTION${AB_CURRENT_MODULE:+ of $AB_CURRENT_MODULE} [$(config_hash "${HOST_UNIT_PROPERTIES[@]}" ${env[@]+"${env[@]}"} "$@")]"
  if [[ "${AB_RESTART:-}" != 1 ]] && host_unit_is "$name" "$desc"; then
    return 0
  fi
  systemctl --user stop "$name.service" >/dev/null 2>&1 || true
  # --collect: a unit that failed is unloaded, so the next start can reuse
  # the name. A start running at the same time may have started the same
  # unit in between: then the name is taken, and that is fine.
  if ! systemd-run --user --quiet --collect --unit="$name" --description="$desc" \
         "${HOST_UNIT_PROPERTIES[@]}" ${env[@]+"${env[@]}"} -- "$@" \
     && ! host_unit_is "$name" "$desc"; then
    ab_error "could not start the host service $name (systemctl --user status $name)"
    exit 1
  fi
}

host_unit_is() {  # <name> <description>: 0 if it runs with that description
  systemctl --user is-active --quiet "$1.service" \
    && [[ "$(systemctl --user show -p Description --value "$1.service")" == "$2" ]]
}

# Stops agentbox host services this start did not ask for: those of MCP
# modules no longer in AB_MCP. Only units agentbox started (by their
# description), never one of yours that happens to share the prefix.
host_units_cleanup() {
  local unit module wanted=" ${HOST_UNITS_WANTED[*]} "
  command -v systemctl >/dev/null || return 0
  while read -r unit module; do
    [[ -n "$unit" ]] || continue
    [[ "$wanted" == *" ${unit%.service} "* ]] && continue
    skipped_keeps "$module" "${unit%.service}" && continue
    if systemctl --user stop "$unit" >/dev/null 2>&1; then
      echo "agentbox: stopped $unit, no longer enabled" >&2
    fi
  done < <(host_units_list)
}

# agentbox's host services that are loaded, "<unit> <module>" per line: the
# module from the description ("agentbox host service of <module> [...]"),
# empty for one started before the mark.
host_units_list() {
  local unit desc module
  for unit in $(systemctl --user list-units --all --plain --no-legend 'agentbox-*.service' 2>/dev/null | awk '{ print $1 }'); do
    desc="$(systemctl --user show -p Description --value "$unit" 2>/dev/null)"
    [[ "$desc" == "$HOST_UNIT_DESCRIPTION "* ]] || continue
    module=""
    [[ "$desc" =~ ^"$HOST_UNIT_DESCRIPTION of "([^ ]+)" " ]] && module="${BASH_REMATCH[1]}"
    echo "$unit $module"
  done
}

# Networks
#   ab-internal: --internal, no route to the outside world. The agent lives here.
#   ab-egress:   normal network. Only sidecars are attached to it.
networks_create() {
  podman network exists ab-internal || podman network create --internal ab-internal >/dev/null
  podman network exists ab-egress   || podman network create ab-egress >/dev/null
}

# OpenAI for pi (optional): enabled only if the openai_api_key secret exists.
#   ab-llm-openai  nginx on both networks: checks the caller token, replaces it
#                  with the real API key and forwards to api.openai.com with
#                  certificate verification (pi/llm-openai.conf.template).
# pi points its built-in openai provider at this sidecar (pi/models.json), so
# the API key never enters the agent container.
openai_start() {
  secret_exists openai_api_key || return 0
  ensure_caller_secret llm_openai_caller
  start_sidecar ab-llm-openai \
    --network ab-internal --network ab-egress \
    --secret openai_api_key,type=env,target=OPENAI_API_KEY \
    --secret llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN \
    -v "$(sidecar_copy ab-llm-openai "$SCRIPT_DIR/pi/llm-openai.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
