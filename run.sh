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
#   GRAFANA_URL       Grafana base URL used by the Grafana MCP sidecar (required)
#   GRAYLOG_URL       Graylog base URL used by the Graylog auth sidecar (required)
#   GH_TOOLSETS       GitHub MCP toolsets (default: context,repos,issues,pull_requests,actions)
#   AB_UPDATE=1       force an update of the agent before starting
#   AB_UPDATE_EVERY   minimum seconds between automatic updates (default: 6h)
#   AB_RESTART=1      recreate sidecar containers (needed after config changes)
#   AB_UPGRADE=1      upgrade everything: pull sidecar images, rebuild the base
#                     image from scratch, update Claude Code, recreate sidecars
#   AB_SKILLS_DIR     host directory with personal skills, mounted read-only
#                     into the agent's skills directory (default: <script dir>/skills)
#   AB_ENV_DIR        host directory with per-project environment files,
#                     <repo dir name>.env (default: <script dir>/env)
#
# See README.md for first-time setup (networks, secrets, MCP registration).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Arguments. If the first argument is an existing directory, it is the repo;
# otherwise the repo is the current directory and ALL arguments go to claude.
# Paths are resolved relative to the CALLER's working directory, before
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
# Configuration file: KEY=VALUE lines, # comments, optional quotes.
# Parsed, not sourced, so it cannot run code, and only the keys below are
# accepted. A variable already set in the environment wins over the file.
# ---------------------------------------------------------------------------
CONFIG_KEYS=(GRAFANA_URL GRAYLOG_URL GH_TOOLSETS AB_SKILLS_DIR AB_UPDATE_EVERY AB_SERVICES AB_ENV_DIR)
load_config() {
  local file="$1" line key val n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line#"${line%%[![:space:]]*}"}"            # trim leading space
    line="${line%"${line##*[![:space:]]}"}"            # trim trailing space
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    if [[ "$line" != *=* ]]; then
      echo "agentbox: warning: $file:$n: not KEY=VALUE, ignored" >&2
      continue
    fi
    key="${line%%=*}"; val="${line#*=}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    if [[ " ${CONFIG_KEYS[*]} " != *" $key "* ]]; then
      echo "agentbox: warning: $file:$n: unknown key '$key', ignored" >&2
      continue
    fi
    if [[ -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$val"
    fi
  done < "$file"
}
CONFIG_FILE="${AB_CONFIG:-$SCRIPT_DIR/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  load_config "$CONFIG_FILE"
elif [[ -n "${AB_CONFIG:-}" ]]; then
  echo "error: AB_CONFIG=$AB_CONFIG does not exist" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
missing_cfg=()
[[ -n "${GRAFANA_URL:-}" ]] || missing_cfg+=(GRAFANA_URL)
[[ -n "${GRAYLOG_URL:-}" ]] || missing_cfg+=(GRAYLOG_URL)
if (( ${#missing_cfg[@]} )); then
  echo "error: not configured: ${missing_cfg[*]}" >&2
  echo "       set them in $CONFIG_FILE (see config.env.example) or in the environment" >&2
  exit 2
fi
GH_TOOLSETS="${GH_TOOLSETS:-context,repos,issues,pull_requests,actions}"

# Normalize base URLs: GRAYLOG_URL must be the Graylog base URL, the nginx
# sidecar appends /api/mcp itself. Accept common mistakes like a trailing
# slash or a URL that already ends in /api or /api/mcp.
GRAYLOG_URL="${GRAYLOG_URL%/}"
GRAYLOG_URL="${GRAYLOG_URL%/api/mcp}"
GRAYLOG_URL="${GRAYLOG_URL%/api}"
GRAFANA_URL="${GRAFANA_URL%/}"

IMAGE="localhost/agentbox"
IMG_SQUID="docker.io/ubuntu/squid:latest"
IMG_GRAFANA="docker.io/grafana/mcp-grafana:latest"
IMG_NGINX="docker.io/library/nginx:alpine"
IMG_GITHUB="ghcr.io/github/github-mcp-server:latest"
# Map the host user to uid/gid 1000 (the "node" user in the image),
# so files written in the repo are owned by you on the host.
USERNS="keep-id:uid=1000,gid=1000"
UPDATE_EVERY="${AB_UPDATE_EVERY:-$((6 * 3600))}"

# ---------------------------------------------------------------------------
# Agent. Each agent is an npm package installed into its own tools volume,
# mounted read-only into the session (see "Agent update" below), and has its
# own home volume: configs, sessions and credentials of one agent are not
# visible to, or writable by, the other. Only caches are shared (see below).
# ---------------------------------------------------------------------------
AGENT="${AB_AGENT:-claude}"
case "$AGENT" in
  claude)
    AGENT_PKG="@anthropic-ai/claude-code"
    AGENT_VOL="ab-claude-tools"; AGENT_PREFIX="/opt/claude"
    AGENT_HOME="ab-claude-home"
    AGENT_INSTALL_FLAGS=()
    AGENT_SECRETS=(claude_oauth)
    ;;
  pi)
    AGENT_PKG="@earendil-works/pi-coding-agent"
    AGENT_VOL="ab-pi-tools"; AGENT_PREFIX="/opt/pi"
    AGENT_HOME="ab-pi-home"
    # As in pi's own container docs: no install scripts.
    AGENT_INSTALL_FLAGS=(--ignore-scripts)
    # No required secret: with a ChatGPT subscription pi signs in itself
    # (/login, stored in ab-pi-home); with an API key, openai_api_key enables the
    # ab-llm-openai sidecar.
    AGENT_SECRETS=()
    ;;
  *)
    echo "error: AB_AGENT must be 'claude' or 'pi', got '$AGENT'" >&2
    exit 2
    ;;
esac
AGENT_BIN="$AGENT_PREFIX/bin/$AGENT"
STAMP="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox.$AGENT.updated"

# ---------------------------------------------------------------------------
# Preflight: required secrets must exist (see README, step 5)
# ---------------------------------------------------------------------------
missing=()
for s in ${AGENT_SECRETS[@]+"${AGENT_SECRETS[@]}"} grafana_sa graylog_basic; do
  podman secret inspect "$s" >/dev/null 2>&1 || missing+=("$s")
done
if (( ${#missing[@]} )); then
  echo "error: missing podman secrets: ${missing[*]} (see README.md, step 5)" >&2
  exit 1
fi

# Caller auth for the Grafana MCP sidecar. Not a Grafana credential: it only
# proves the caller may talk to the sidecar. Generated once, automatically.
if ! podman secret inspect grafana_mcp_caller >/dev/null 2>&1; then
  head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | podman secret create grafana_mcp_caller - >/dev/null
  echo "agentbox: created secret grafana_mcp_caller; re-register the grafana MCP server (README, step 6)" >&2
fi

# ---------------------------------------------------------------------------
# Networks
#   ab-internal: --internal, no route to the outside world. Claude lives here.
#   ab-egress:   normal network. Only sidecars are attached to it.
# ---------------------------------------------------------------------------
podman network exists ab-internal || podman network create --internal ab-internal >/dev/null
podman network exists ab-egress   || podman network create ab-egress >/dev/null

# ---------------------------------------------------------------------------
# Local services (AB_SERVICES): your own dev containers (databases, queues)
# the agent may use, e.g. "redis rabbitmq postgres". Each is attached to
# ab-services, a separate --internal network the session joins, and is
# reachable by container name (redis:6379). Kept apart from ab-internal so
# these containers cannot reach the MCP/LLM sidecars, and the session gets no
# route to the host or the internet through them. Attachment is persistent;
# undo with: podman network disconnect ab-services <name>.
# Only rootless Podman containers of the same user can be attached.
# ---------------------------------------------------------------------------
service_net=()
if [[ -n "${AB_SERVICES:-}" ]]; then
  podman network exists ab-services || podman network create --internal ab-services >/dev/null
  read -ra services <<< "${AB_SERVICES//,/ }"
  for svc in "${services[@]}"; do
    if ! podman container exists "$svc"; then
      echo "agentbox: warning: AB_SERVICES: no container '$svc' (rootless podman of this user), skipped" >&2
      continue
    fi
    # Containers started without --network use pasta/slirp4netns (rootless
    # default) and cannot join any network later; they must be recreated
    # on a bridge network (README, Local services).
    mode="$(podman inspect --format '{{.HostConfig.NetworkMode}}' "$svc")"
    if [[ "$mode" == pasta* || "$mode" == slirp4netns* || "$mode" == host || "$mode" == none ]]; then
      echo "agentbox: warning: '$svc' uses network mode '$mode' and cannot be attached;" \
           "recreate it with --network ab-services (see README, Local services)" >&2
      continue
    fi
    if ! podman inspect --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}' "$svc" \
         | grep -qw ab-services; then
      podman network connect ab-services "$svc" \
        || echo "agentbox: warning: could not attach '$svc' to ab-services" >&2
    fi
  done
  service_net=(--network ab-services)
fi

# ---------------------------------------------------------------------------
# Full upgrade. podman never re-pulls an image it already has, and a cached
# build never re-runs apt-get, so without this nothing but Claude Code updates.
# ---------------------------------------------------------------------------
if [[ "${AB_UPGRADE:-}" == 1 ]]; then
  echo "agentbox: upgrading images..." >&2
  for img in "$IMG_SQUID" "$IMG_GRAFANA" "$IMG_NGINX" "$IMG_GITHUB"; do
    podman pull -q "$img" >/dev/null
  done
  podman build --pull --no-cache -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
  AB_UPDATE=1
  AB_RESTART=1
fi

# ---------------------------------------------------------------------------
# Image: tooling only (node, git, ripgrep). Claude Code itself is NOT baked in.
# Rebuild manually after editing the Containerfile: podman rmi localhost/agentbox
# ---------------------------------------------------------------------------
podman image exists "$IMAGE" || podman build -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Agent update.
# Runs in a short-lived container that HAS internet access but has neither the
# repo nor the agent. Installs into the agent's tools volume, which the session
# container mounts read-only, so the agent can't tamper with its own binary.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$STAMP")"
if [[ "${AB_UPDATE:-}" == 1 || ! -f "$STAMP" ]] \
   || (( $(date +%s) - $(stat -c %Y "$STAMP") > UPDATE_EVERY )); then
  echo "agentbox: updating $AGENT..." >&2
  if podman run --rm --network ab-egress --userns="$USERNS" \
       -v "$AGENT_VOL:$AGENT_PREFIX" \
       --entrypoint npm "$IMAGE" \
       install -g "${AGENT_INSTALL_FLAGS[@]}" --prefix "$AGENT_PREFIX" "$AGENT_PKG@latest" >&2; then
    touch "$STAMP"
  else
    echo "agentbox: warning: update failed, using the installed version" >&2
  fi
fi
if ! podman run --rm -v "$AGENT_VOL:$AGENT_PREFIX:ro" --entrypoint test "$IMAGE" -x "$AGENT_BIN"; then
  echo "error: $AGENT is not installed in the $AGENT_VOL volume (run with AB_UPDATE=1)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Prepare the agent's home volume (one short-lived container, no network).
#
# 1. Ownership of mount-point parents. Read-only config and skills are
#    bind-mounted into ~/.claude or ~/.pi/agent. Podman creates missing parents
#    of a mount point as root, so on a fresh volume the agent could not write
#    its own config directory (e.g. pi failed to create ~/.pi/agent/sessions).
#    Create them as node first; chown also repairs volumes already affected.
#    Runs as root inside the user namespace: uid 0 there is a subuid on the
#    host, uid 1000 (node) is you.
#
# 2. Claude Code only: skip the first-run onboarding wizard. Interactive
#    Claude Code may ignore CLAUDE_CODE_OAUTH_TOKEN during onboarding and show
#    the browser login picker (anthropics/claude-code#46259). Setting
#    hasCompletedOnboarding in ~/.claude.json is the documented workaround.
#    Merges into the existing file, other settings are preserved.
#
# 3. Claude Code only: auto memory off by default. Set only when
#    ~/.claude/settings.json has no autoMemoryEnabled yet, so an explicit
#    choice there stays; a project enables it in its .claude/settings.json.
#    An unreadable settings file is left alone.
# ---------------------------------------------------------------------------
case "$AGENT" in
  claude) home_dirs=(.claude) ;;
  pi)     home_dirs=(.pi .pi/agent) ;;
esac
podman run --rm --network none --userns="$USERNS" --user 0 \
  -e AGENT="$AGENT" \
  -v "$AGENT_HOME:/home/node" \
  --entrypoint sh "$IMAGE" -c '
    set -eu
    cd /home/node
    for d in "$@"; do
      mkdir -p "$d"
      chown node:node "$d"
    done
    if [ "$AGENT" = claude ]; then
      node -e "
        const fs = require(\"fs\"), f = \"/home/node/.claude.json\";
        let c = {};
        try { c = JSON.parse(fs.readFileSync(f, \"utf8\")); } catch (e) {}
        if (c.hasCompletedOnboarding !== true) {
          c.hasCompletedOnboarding = true;
          fs.writeFileSync(f, JSON.stringify(c, null, 2), { mode: 0o600 });
        }
        const s = \"/home/node/.claude/settings.json\";
        let t = {}, ok = true;
        try { t = JSON.parse(fs.readFileSync(s, \"utf8\")); } catch (e) { ok = e.code === \"ENOENT\"; }
        if (ok && t && typeof t === \"object\" && t.autoMemoryEnabled === undefined) {
          t.autoMemoryEnabled = false;
          fs.writeFileSync(s, JSON.stringify(t, null, 2));
        }"
      chown node:node /home/node/.claude.json /home/node/.claude/settings.json
    fi
  ' sh "${home_dirs[@]}"

# ---------------------------------------------------------------------------
# Sidecars. Started once and reused across sessions, so several sessions can
# run in parallel. Set AB_RESTART=1 to recreate them after changing config.
# ---------------------------------------------------------------------------
start_sidecar() {
  local name="$1"; shift
  if [[ "${AB_RESTART:-}" != 1 ]] \
     && [[ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    return 0
  fi
  podman run -d --replace --name "$name" "$@" >/dev/null
}

# Egress proxy: the only way out for the Claude container (allowlist in squid.conf).
start_sidecar ab-egress \
  --network ab-internal --network ab-egress \
  -v "$SCRIPT_DIR/squid.conf:/etc/squid/squid.conf:ro,Z" \
  "$IMG_SQUID"

# Grafana MCP: the service account token exists only in this container.
#   MCP_GRAFANA_SERVER_TOKEN   callers must send "Authorization: Bearer <token>"
#   GRAFANA_USAGE_STATS        no anonymous usage reporting to Grafana Labs
#   --allowed-hosts            DNS-rebinding protection: only accept the Host
#                              header the Claude container sends
#   --disable-write            no write operations to Grafana, on top of the
#                              Viewer role of the service account
start_sidecar ab-mcp-grafana \
  --network ab-internal --network ab-egress \
  -e GRAFANA_URL="$GRAFANA_URL" \
  -e GRAFANA_USAGE_STATS=disabled \
  --secret grafana_sa,type=env,target=GRAFANA_SERVICE_ACCOUNT_TOKEN \
  --secret grafana_mcp_caller,type=env,target=MCP_GRAFANA_SERVER_TOKEN \
  "$IMG_GRAFANA" \
  -t streamable-http --address 0.0.0.0:8000 \
  --allowed-hosts ab-mcp-grafana:8000,ab-mcp-grafana \
  --disable-write

# Graylog MCP: nginx injects the Authorization header, Claude never sees the token.
start_sidecar ab-mcp-graylog \
  --network ab-internal --network ab-egress \
  -e GRAYLOG_URL="$GRAYLOG_URL" \
  --secret graylog_basic,type=env,target=GRAYLOG_BASIC \
  -v "$SCRIPT_DIR/graylog-mcp.conf.template:/etc/nginx/templates/default.conf.template:ro,Z" \
  "$IMG_NGINX"

# GitHub MCP (optional): enabled only if the github_pat secret exists.
#   ab-mcp-github-srv  github-mcp-server, ab-egress only, so Claude can't reach
#                      it directly; it has no token of its own
#   ab-mcp-github      nginx on both networks: checks the caller token, injects
#                      the PAT and pins toolsets/lockdown (github-mcp.conf.template)
if podman secret inspect github_pat >/dev/null 2>&1; then
  if ! podman secret inspect github_mcp_caller >/dev/null 2>&1; then
    head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | podman secret create github_mcp_caller - >/dev/null
    echo "agentbox: created secret github_mcp_caller; register the github MCP server (README, GitHub)" >&2
  fi
  start_sidecar ab-mcp-github-srv \
    --network ab-egress \
    "$IMG_GITHUB" http
  start_sidecar ab-mcp-github \
    --network ab-internal --network ab-egress \
    -e GH_TOOLSETS="$GH_TOOLSETS" \
    --secret github_pat,type=env,target=GH_PAT \
    --secret github_mcp_caller,type=env,target=GH_CALLER_TOKEN \
    -v "$SCRIPT_DIR/github-mcp.conf.template:/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
fi

# OpenAI for pi (optional): enabled only if the openai_api_key secret exists.
#   ab-llm-openai  nginx on both networks: checks the caller token, replaces it
#                  with the real API key and forwards to api.openai.com with
#                  certificate verification (llm-openai.conf.template).
# pi points its built-in openai provider at this sidecar (pi/models.json), so
# the API key never enters the agent container.
if podman secret inspect openai_api_key >/dev/null 2>&1; then
  if ! podman secret inspect llm_openai_caller >/dev/null 2>&1; then
    head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | podman secret create llm_openai_caller - >/dev/null
  fi
  start_sidecar ab-llm-openai \
    --network ab-internal --network ab-egress \
    --secret openai_api_key,type=env,target=OPENAI_API_KEY \
    --secret llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN \
    -v "$SCRIPT_DIR/llm-openai.conf.template:/etc/nginx/templates/default.conf.template:ro,Z" \
    "$IMG_NGINX"
fi

# ---------------------------------------------------------------------------
# Git identity from the host (repo-local config first, then global).
# Only passed if set, an empty GIT_AUTHOR_NAME makes git refuse to commit.
# ---------------------------------------------------------------------------
git_env=()
git_name="$(git -C "$REPO" config user.name 2>/dev/null || true)"
git_email="$(git -C "$REPO" config user.email 2>/dev/null || true)"
if [[ -n "$git_name" ]]; then
  git_env+=(-e "GIT_AUTHOR_NAME=$git_name" -e "GIT_COMMITTER_NAME=$git_name")
fi
if [[ -n "$git_email" ]]; then
  git_env+=(-e "GIT_AUTHOR_EMAIL=$git_email" -e "GIT_COMMITTER_EMAIL=$git_email")
fi

# ---------------------------------------------------------------------------
# Protect .git/hooks and .git/config. Both are executed/interpreted by git on
# the HOST (hooks, core.fsmonitor, core.sshCommand, ...), so a writable copy
# would let the agent run code outside the container on your next git command.
# ---------------------------------------------------------------------------
git_mounts=()
if [[ -d "$REPO/.git" ]]; then
  mkdir -p "$REPO/.git/hooks"
  git_mounts+=(
    -v "$REPO/.git/hooks:$WORK_DIR/.git/hooks:ro,z"
    -v "$REPO/.git/config:$WORK_DIR/.git/config:ro,z"
  )
elif [[ -f "$REPO/.git" ]]; then
  echo "agentbox: warning: $REPO is a git worktree or submodule;" \
       "its git dir is outside the mount, so git will not work inside the container" >&2
fi

# ---------------------------------------------------------------------------
# Personal skills: one subdirectory per skill, each with a SKILL.md.
# Mounted read-only over ~/.claude/skills so the agent cannot rewrite its own
# skills (they would otherwise persist in ab-claude-home across sessions and repos).
# Project skills in <repo>/.claude/skills need nothing: the repo is mounted.
# ---------------------------------------------------------------------------
SKILLS_DIR="${AB_SKILLS_DIR:-$SCRIPT_DIR/skills}"
SKILLS_SRC=""
if [[ -d "$SKILLS_DIR" ]]; then
  SKILLS_SRC="$(realpath -e -- "$SKILLS_DIR")"
fi

# ---------------------------------------------------------------------------
# Shared caches. Both agents mount the same two cache volumes, which hold no
# configuration and no credentials:
#   ab-cache -> ~/.cache  uv cache, Go build cache, per-repo virtualenvs
#   ab-go    -> ~/go      Go module cache and `go install` binaries
#
# Python virtualenv per repo, OUTSIDE the repo: uv puts the project env at
# UV_PROJECT_ENVIRONMENT instead of <repo>/.venv, so a .venv you use on the
# host is never overwritten with container paths, and vice versa. Kept in
# ab-cache, keyed by repo name + path hash, so both agents use the same env.
# ---------------------------------------------------------------------------
venv_key="$(basename "$REPO")-$(printf '%s' "$REPO" | sha256sum | cut -c1-8)"

# ---------------------------------------------------------------------------
# Per-project environment: <env dir>/<repo dir name>.env, if present, goes to
# the session as --env-file (podman format: KEY=VALUE per line, # comments,
# the value is taken literally, quotes included). Different projects can give
# the same variable (DB_CONN) different values, and only the box sees them:
# the agent on the host does not. The file stays on the host, outside the
# repo, so the agent cannot change what its next session starts with, and
# passwords in it never reach the project's git. Keyed by directory name:
# two repos with the same name share one file. The -e options below take
# precedence over --env-file, so it cannot override the proxy or agent setup.
# ---------------------------------------------------------------------------
ENV_DIR="${AB_ENV_DIR:-$SCRIPT_DIR/env}"
env_file_args=()
env_file="$ENV_DIR/$(basename "$REPO").env"
if [[ -f "$env_file" ]]; then
  env_file_args=(--env-file "$env_file")
  echo "agentbox: env $env_file" >&2
fi

# Allocate a TTY only when attached to a terminal (keeps piping/scripts working).
tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags+=(-t)

# ---------------------------------------------------------------------------
# Agent-specific settings
# ---------------------------------------------------------------------------
agent_args=(-v "$AGENT_VOL:$AGENT_PREFIX:ro")
case "$AGENT" in
  claude)
    # ENABLE_CLAUDEAI_MCP_SERVERS=false  don't pull in connectors configured on
    #                                    claude.ai (Gmail, Slack, ...), only the
    #                                    MCP servers registered in this box
    # CLAUDE_CODE_DISABLE_ARTIFACT=1     no artifact reads from claudeusercontent.com
    agent_args+=(
      -e ENABLE_CLAUDEAI_MCP_SERVERS=false
      -e CLAUDE_CODE_DISABLE_ARTIFACT=1
      --secret "claude_oauth,type=env,target=CLAUDE_CODE_OAUTH_TOKEN"
    )
    if [[ -n "$SKILLS_SRC" ]]; then
      agent_args+=(-v "$SKILLS_SRC:/home/node/.claude/skills:ro,z")
    fi
    # Personal instructions for every repo, from the host and read-only for
    # the same reason as skills: written in ab-claude-home by the agent, they
    # would persist into every future session.
    if [[ -f "$SCRIPT_DIR/claude/CLAUDE.md" ]]; then
      agent_args+=(-v "$SCRIPT_DIR/claude/CLAUDE.md:/home/node/.claude/CLAUDE.md:ro,z")
    fi
    ;;
  pi)
    # PI_OFFLINE, PI_SKIP_VERSION_CHECK, PI_TELEMETRY: no model catalog refresh,
    # no version check, no telemetry. Model traffic goes either to
    # api.openai.com via squid (ChatGPT subscription, "Sign in with ChatGPT")
    # or through the ab-llm-openai sidecar (API key); tools go through the MCP
    # sidecars.
    # models.json, mcp.json, skills/ and extensions/ come from the host,
    # read-only: the agent cannot redirect its model, add MCP servers, or plant
    # extensions (which pi loads and executes) that would persist in ab-pi-home.
    # The caller tokens below only grant access to the sidecars.
    mkdir -p "$SCRIPT_DIR/pi/extensions"
    agent_args+=(
      --entrypoint "$AGENT_BIN"
      -e PI_OFFLINE=1
      -e PI_SKIP_VERSION_CHECK=1
      -e PI_TELEMETRY=0
      --secret "grafana_mcp_caller,type=env,target=GRAFANA_MCP_TOKEN"
      -v "$SCRIPT_DIR/pi/mcp.json:/home/node/.pi/agent/mcp.json:ro,z"
      -v "$SCRIPT_DIR/pi/extensions:/home/node/.pi/agent/extensions:ro,z"
    )
    if podman secret inspect github_mcp_caller >/dev/null 2>&1; then
      agent_args+=(--secret "github_mcp_caller,type=env,target=GITHUB_MCP_TOKEN")
    fi
    # API-key mode only (openai_api_key secret exists): pi/models.json points
    # the openai provider at the ab-llm-openai sidecar. In subscription mode it
    # must NOT be mounted, or "Sign in with ChatGPT" requests would go to the
    # sidecar instead of api.openai.com.
    if podman secret inspect openai_api_key >/dev/null 2>&1 \
       && podman secret inspect llm_openai_caller >/dev/null 2>&1; then
      agent_args+=(
        --secret "llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN"
        -v "$SCRIPT_DIR/pi/models.json:/home/node/.pi/agent/models.json:ro,z"
      )
    fi
    if [[ -n "$SKILLS_SRC" ]]; then
      agent_args+=(-v "$SKILLS_SRC:/home/node/.pi/agent/skills:ro,z")
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# SELinux labels for host directories used by sessions: lowercase ":z" (shared)
# on everything a session mounts from the host (repo, .git parts, skills, pi
# config). Uppercase ":Z" gives a directory a label private to ONE container,
# so a second session (Claude + pi in the same repo, or two sessions sharing
# skills/) relabels it and the first one loses access. Sidecar config files
# are each used by a single container and keep ":Z".
#
# Session: internal network only, no host credentials, read-only agent binary.
# ---------------------------------------------------------------------------
exec podman run --rm "${tty_flags[@]}" \
  --name "ab-$AGENT-$$" \
  --network ab-internal \
  "${service_net[@]}" \
  --userns="$USERNS" \
  --cap-drop=ALL --security-opt no-new-privileges \
  "${env_file_args[@]}" \
  -e HTTPS_PROXY=http://ab-egress:3128 \
  -e HTTP_PROXY=http://ab-egress:3128 \
  -e NO_PROXY=ab-mcp-grafana,ab-mcp-graylog,ab-mcp-github,ab-llm-openai \
  -e "UV_PROJECT_ENVIRONMENT=/home/node/.cache/venvs/$venv_key" \
  "${git_env[@]}" \
  -v "$AGENT_HOME:/home/node" \
  -v ab-cache:/home/node/.cache \
  -v ab-go:/home/node/go \
  -v "$REPO:$WORK_DIR:z" \
  --workdir "$WORK_DIR" \
  "${git_mounts[@]}" \
  "${agent_args[@]}" \
  "$IMAGE" "$@"
