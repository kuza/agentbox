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
# Settings come from config.env next to this script (see config.env.example),
# or from the file named by AB_CONFIG. Environment variables override the file.
#
# Settings / environment overrides:
#   AB_CONFIG         path of the config file (default: <script dir>/config.env)
#   AB_AGENT          claude (default) or pi
#   AB_MCP            MCP modules to enable, e.g. "grafana graylog github"; each
#                     from mcp.local/<name>/ or mcp/<name>/, with its own
#                     settings (GRAFANA_URL, ...). context7 is always on.
#   AB_UPDATE=1       force an update of the agent before starting
#   AB_UPDATE_EVERY   minimum seconds between automatic updates (default: 6h)
#   AB_RESTART=1      recreate sidecar containers (needed after config changes)
#   AB_UPGRADE=1      upgrade everything: pull sidecar images, rebuild the base
#                     image from scratch, update Claude Code, recreate sidecars
#   AB_CHECK_UPDATES=0  skip the check for newer sidecar images and vendored
#                     skills before the session (check-updates.sh)
#   AB_SERVICES       your dev containers the session may reach by name,
#                     e.g. "redis rabbitmq" (README, Local services)
#   AB_GRAPHIFY_EXTRAS  graphify extras baked into the image, e.g. "[terraform]"
#                     (default: none); applies on the next build (AB_UPGRADE=1)
#   AB_SKILLS_DIR     host directory with personal skills, mounted read-only
#                     into the agent's skills directory (default: <script dir>/skills)
#   AB_ENV_DIR        host directory with per-project environment files,
#                     <repo dir name>.env (default: <script dir>/env)
#
#
# The steps live in lib/*.sh, MCP servers in mcp/*/mcp.sh (README, MCP servers).
# See README.md for first-time setup (networks, secrets).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for lib in config agent sidecars mcp services skills session; do
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
if [[ "$REPO" == "$SCRIPT_DIR" ]]; then
  echo "error: refusing to mount the agentbox directory itself; run from your repo or pass its path" >&2
  exit 2
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
config_first_pass
mcp_init
config_second_pass ${MCP_CONFIG_KEYS[@]+"${MCP_CONFIG_KEYS[@]}"}
UPDATE_EVERY="${AB_UPDATE_EVERY:-$((6 * 3600))}"
BUILD_ARGS=(--build-arg "GRAPHIFY_EXTRAS=${AB_GRAPHIFY_EXTRAS:-}")

skills_init

agent_select
agent_check_secrets
mcp_check_secrets
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
    podman pull -q "$img" >/dev/null
  done
  podman build --pull --no-cache "${BUILD_ARGS[@]}" -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
  AB_UPDATE=1
  AB_RESTART=1
fi

# Image: tooling only (node, git, ripgrep, ...). The agents are NOT baked in.
# Rebuild after editing the Containerfile: AB_UPGRADE=1, or podman rmi localhost/agentbox
podman image exists "$IMAGE" \
  || podman build "${BUILD_ARGS[@]}" -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"

agent_update
agent_prepare_home

mcp_write_configs
egress_start
mcp_start_all
openai_start

skills_prepare
session_git_env
session_tz
session_git_mounts
session_env_file
session_agent_args
session_exec "$@"
