#!/usr/bin/env bash
# agentbox: run a coding agent (Claude Code or pi) inside an isolated
# rootless Podman container.
#
# Usage:
#   run.sh [repo-dir] [agent args...]          Claude Code
#   pi.sh  [repo-dir] [agent args...]          pi (same as AB_AGENT=pi run.sh)
#
# If the first argument is an existing directory, it is mounted as the repo.
# Otherwise the current directory is used and all arguments go to the agent.
#
# Examples:
#   run.sh                                       # current directory
#   run.sh ~/src/myrepo --dangerously-skip-permissions
#   run.sh mcp list                              # current dir, any claude subcommand
#
# Settings come from config.env in AB_HOME (see config.env.example), or from
# the file named by AB_CONFIG. Environment variables override the file. Your
# files live in AB_HOME, apart from this code (lib/paths.sh).
#
# Settings / environment overrides:
#   AB_HOME           directory with your files (default: ~/.config/agentbox)
#   AB_CONFIG         path of the config file (default: <AB_HOME>/config.env)
#   AB_AGENT          claude (default), pi, or shell: bash in the same box
#                     instead of an agent, arguments go to bash (README,
#                     Escape checks)
#   AB_MCP            MCP modules to enable, e.g. "grafana graylog github"; each
#                     from <AB_HOME>/mcp.local/<name>/ or mcp/<name>/, with its own
#                     settings (GRAFANA_URL, ...). context7 is always on.
#   AB_EGRESS         egress host groups to enable, e.g. "pypi go gcs"; each
#                     from <AB_HOME>/egress.local.d/ or egress.d/ (default:
#                     anthropic openai pypi go)
#   AB_UPDATE=1       force an update of the agent before starting
#   AB_UPDATE_EVERY   minimum seconds between automatic updates (default: 6h)
#   AB_RESTART=1      recreate sidecar containers (needed after config changes)
#   AB_UPGRADE=1      upgrade everything: pull sidecar images, rebuild the base
#                     image from scratch, update Claude Code, recreate sidecars
#   AB_CHECK_UPDATES=0  skip the check for newer sidecar images and vendored
#                     skills before the session (check-updates.sh)
#   AB_SERVICES       your dev containers the session may reach by name,
#                     e.g. "redis rabbitmq" (README, Local services)
#   AB_FORWARD        services outside the box the session may reach by name,
#                     e.g. "db=db.test.example:5432"; also per repo in
#                     <env dir>/<repo dir name>.conf (README, Test servers)
#   AB_GRAPHIFY_EXTRAS  graphify extras baked into the image, e.g. "[terraform]"
#                     (default: none); applies on the next build (AB_UPGRADE=1)
#   AB_PYTHON_VERSIONS, AB_GO_VERSION, AB_GOLANGCI_LINT_VERSION
#                     tool versions baked into the image (default: the
#                     Containerfile's); apply on the next build (AB_UPGRADE=1)
#   AB_SKILLS_DIR     host directory with personal skills, mounted read-only
#                     into the agent's skills directory (default: <AB_HOME>/skills)
#   AB_ENV_DIR        host directory with per-project environment files,
#                     <repo dir name>.env (default: <AB_HOME>/env)
#
#
# The steps live in lib/*.sh, MCP servers in mcp/*/mcp.sh (README, MCP servers),
# egress host groups in egress.d/ (README, Egress).
# See README.md for first-time setup (networks, secrets).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
for lib in config images agent sidecars mcp egress forward services skills session; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/$lib.sh"
done

# ---------------------------------------------------------------------------
# Arguments. If the first argument is an existing directory, it is the repo;
# otherwise the repo is the current directory and ALL arguments go to the
# agent. Paths are resolved relative to the CALLER's working directory, before
# anything else, so "." and "../repo" mount what you expect.
# ---------------------------------------------------------------------------
if [[ $# -gt 0 && -d "$1" ]]; then
  REPO="$(realpath -e -- "$1")"
  shift
else
  REPO="$(realpath -e -- "$PWD")"
fi
echo "agentbox: repo $REPO" >&2
# Mount point inside the session, named after the repo directory. Agents key
# their per-project state by working directory (Claude Code: memory, session
# history, project permissions), so one fixed path for every repo would make
# all repos one project. Two repos with the same name still share that state.
WORK_DIR="/work/$(basename "$REPO")"

# ---------------------------------------------------------------------------
# Configuration: agentbox's settings, then the enabled MCP modules' settings.
# ---------------------------------------------------------------------------
user_paths_check_old
config_first_pass
mcp_init
config_second_pass ${MCP_CONFIG_KEYS[@]+"${MCP_CONFIG_KEYS[@]}"}
UPDATE_EVERY="${AB_UPDATE_EVERY:-$((6 * 3600))}"
# A number of seconds; anything else would be evaluated as an arithmetic
# expression, which can run commands.
if [[ ! "$UPDATE_EVERY" =~ ^[0-9]+$ ]]; then
  echo "error: AB_UPDATE_EVERY must be a number of seconds, got '$UPDATE_EVERY'" >&2
  exit 2
fi
# Image build settings from config.env; unset ones keep the Containerfile's
# defaults (an empty AB_GO_VERSION or AB_GOLANGCI_LINT_VERSION means latest).
BUILD_ARGS=(--build-arg "GRAPHIFY_EXTRAS=${AB_GRAPHIFY_EXTRAS:-}")
for arg in PYTHON_VERSIONS GO_VERSION GOLANGCI_LINT_VERSION; do
  var="AB_$arg"
  [[ -n "${!var+x}" ]] && BUILD_ARGS+=(--build-arg "$arg=${!var}")
done

skills_init
user_paths_check_repo "$REPO" "${AB_ENV_DIR:-$USER_ENV_DIR}" "$SKILLS_DIR" "$CONFIG_FILE"

agent_select
agent_check_secrets
mcp_check_secrets
egress_init
forward_init
networks_create
services_attach

# ---------------------------------------------------------------------------
# Update check: newer sidecar images and vendored skills, with an offer to
# update them (check-updates.sh), at most every UPDATE_EVERY seconds like the
# agent update. Before the sidecars start, so recreated ones come up on the
# new image. AB_UPGRADE updates everything anyway.
# ---------------------------------------------------------------------------
if [[ "${AB_CHECK_UPDATES:-1}" != 0 && "${AB_UPGRADE:-}" != 1 ]]; then
  AB_UPDATE_EVERY="$UPDATE_EVERY" AB_SKILLS_DIR="$SKILLS_DIR" "$SCRIPT_DIR/check-updates.sh" --if-due
fi

# ---------------------------------------------------------------------------
# Full upgrade. podman never re-pulls an image it already has, and a cached
# build never re-runs apt-get, so without this nothing but the agent updates.
# ---------------------------------------------------------------------------
if [[ "${AB_UPGRADE:-}" == 1 ]]; then
  echo "agentbox: upgrading images..." >&2
  for img in $(printf '%s\n' "$IMG_SQUID" "$IMG_NGINX" ${MCP_IMAGES_ALL[@]+"${MCP_IMAGES_ALL[@]}"} | sort -u); do
    image_retire "$img"
    podman pull -q "$img" >/dev/null
  done
  image_retire "$IMAGE"
  build_image --pull --no-cache
  AB_UPDATE=1
  AB_RESTART=1
fi

# Image: tooling only (node, git, ripgrep, ...). The agents are NOT baked in.
# Rebuild after editing the Containerfile: AB_UPGRADE=1, or podman rmi localhost/agentbox
podman image exists "$IMAGE" \
  || build_image

agent_update
agent_prepare_home

mcp_write_configs
egress_write_conf
egress_start
mcp_start_all
openai_start
forward_start
sidecars_cleanup
forward_cleanup
images_cleanup

skills_prepare
session_git_env
session_tz
session_git_mounts
session_env_file
session_agent_args
session_exec "$@"
