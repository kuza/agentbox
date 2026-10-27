# Sidecars. Started once and reused across sessions, so several sessions can
# run in parallel. A sidecar is recreated when what it is started with
# changes: its podman run arguments (settings, labels, image tag) or the
# content of the files it mounts. Changes nobody can see from here, such as
# a rotated podman secret, need AB_RESTART=1.

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

start_sidecar() {  # <name> <podman run arguments...>
  local name="$1" hash
  shift
  SIDECARS_WANTED+=("$name")
  hash="$(config_hash "$@")"
  if [[ "${AB_RESTART:-}" != 1 ]] \
     && [[ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]] \
     && [[ "$(podman inspect -f '{{index .Config.Labels "agentbox.config"}}' "$name" 2>/dev/null)" == "$hash" ]] \
     && sidecar_image_current "$name"; then
    return 0
  fi
  # -v: with the container's anonymous volumes (squid declares some), which
  # would otherwise stay behind on every recreation.
  podman rm -f -v "$name" >/dev/null 2>&1 || true
  podman run -d --replace --name "$name" --label "agentbox.config=$hash" "$@" >/dev/null
}

# 0 if the container runs the image its tag names now: a rebuilt squid image
# (image_ensure) or a pulled one keeps the tag, so the arguments alone do not
# show it.
sidecar_image_current() {  # <container>
  local tag id
  tag="$(podman inspect -f '{{.ImageName}}' "$1" 2>/dev/null)" || return 1
  id="$(podman image inspect -f '{{.Id}}' "$tag" 2>/dev/null)" || return 1
  [[ -n "$id" && "$(podman inspect -f '{{.Image}}' "$1" 2>/dev/null)" == "$id" ]]
}

# Removes agentbox sidecars this start did not ask for: those of MCP modules
# no longer in AB_MCP, ab-llm-openai once its key is gone. Sidecars are named
# ab-egress, ab-mcp-* or ab-llm-*. A second agentbox setup with another
# AB_CONFIG on the same host would remove the other's sidecars.
sidecars_cleanup() {
  local name wanted=" ${SIDECARS_WANTED[*]} "
  for name in $(podman ps -a --format '{{.Names}}' | awk '{ print $1 }'); do
    [[ "$name" == ab-egress || "$name" == ab-mcp-* || "$name" == ab-llm-* ]] || continue
    [[ "$wanted" == *" $name "* ]] && continue
    podman rm -f -v "$name" >/dev/null && echo "agentbox: removed $name, no longer enabled" >&2
  done
}

# Config files reach sidecars as copies in the cache, never from the repo.
# A sidecar mounts its files with ":Z", a label private to that container; on
# the repo's own file that label would lock out agent sessions and git in
# them (README, Troubleshooting). Each container gets its own copy, written
# anew and renamed, so a running sidecar keeps the version it mounted.
sidecar_copy() {  # <container> <file>: prints the path of a fresh copy
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars/$1" dst tmp
  dst="$dir/$(basename "$2")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dst.XXXXXX")"
  cp -- "$2" "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$dst"
  printf '%s\n' "$dst"
}

# Caller tokens: a random secret per sidecar that proves the caller may talk
# to it. Not a credential for the service behind it. Generated once.
ensure_caller_secret() {  # <secret name>
  podman secret inspect "$1" >/dev/null 2>&1 && return 0
  random_token | podman secret create "$1" - >/dev/null
  echo "agentbox: created secret $1" >&2
}

random_token() {  # prints 32 random bytes as base64 letters and digits
  head -c 32 /dev/urandom | base64 | tr -d '/+=\n'
}

secret_store() {  # <secret name>: create or replace it with stdin
  # --replace came with podman 4.7; before, the old secret goes first.
  if podman secret create --help 2>/dev/null | grep -q -- '--replace'; then
    podman secret create --replace "$1" - >/dev/null
  else
    podman secret rm "$1" >/dev/null 2>&1 || true
    podman secret create "$1" - >/dev/null
  fi
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
  desc="$HOST_UNIT_DESCRIPTION [$(config_hash "${HOST_UNIT_PROPERTIES[@]}" ${env[@]+"${env[@]}"} "$@")]"
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
    echo "error: could not start the host service $name (systemctl --user status $name)" >&2
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
  local unit wanted=" ${HOST_UNITS_WANTED[*]} "
  command -v systemctl >/dev/null || return 0
  for unit in $(host_units_list); do
    [[ "$wanted" == *" ${unit%.service} "* ]] && continue
    if systemctl --user stop "$unit" >/dev/null 2>&1; then
      echo "agentbox: stopped $unit, no longer enabled" >&2
    fi
  done
}

host_units_list() {  # agentbox's host services that are loaded, one per line
  local unit
  for unit in $(systemctl --user list-units --all --plain --no-legend 'agentbox-*.service' 2>/dev/null | awk '{ print $1 }'); do
    [[ "$(systemctl --user show -p Description --value "$unit" 2>/dev/null)" == "$HOST_UNIT_DESCRIPTION "* ]] && echo "$unit"
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
  podman secret inspect openai_api_key >/dev/null 2>&1 || return 0
  ensure_caller_secret llm_openai_caller
  start_sidecar ab-llm-openai \
    --network ab-internal --network ab-egress \
    --secret openai_api_key,type=env,target=OPENAI_API_KEY \
    --secret llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN \
    -v "$(sidecar_copy ab-llm-openai "$SCRIPT_DIR/pi/llm-openai.conf.template"):/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
}
