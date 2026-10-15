# The session container: environment, mounts, and the agent itself.

# Git identity from the host (repo-local config first, then global).
# Only passed if set, an empty GIT_AUTHOR_NAME makes git refuse to commit.
session_git_env() {
  local name email
  GIT_ENV=()
  name="$(git -C "$REPO" config user.name 2>/dev/null || true)"
  email="$(git -C "$REPO" config user.email 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    GIT_ENV+=(-e "GIT_AUTHOR_NAME=$name" -e "GIT_COMMITTER_NAME=$name")
  fi
  if [[ -n "$email" ]]; then
    GIT_ENV+=(-e "GIT_AUTHOR_EMAIL=$email" -e "GIT_COMMITTER_EMAIL=$email")
  fi
}

# Host time zone, so times in the session (status line reset times, commit
# dates) match the host clock instead of the image's UTC. TZ wins if set.
session_tz() {
  local tz
  TZ_ENV=()
  tz="${TZ:-$(readlink -f /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')}"
  if [[ -n "$tz" ]]; then TZ_ENV=(-e "TZ=$tz"); fi
}

# Protect .git/hooks and .git/config. Both are executed/interpreted by git on
# the HOST (hooks, core.fsmonitor, core.sshCommand, ...), so a writable copy
# would let the agent run code outside the container on your next git command.
session_git_mounts() {
  GIT_MOUNTS=()
  if [[ -d "$REPO/.git" ]]; then
    mkdir -p "$REPO/.git/hooks"
    GIT_MOUNTS+=(
      -v "$REPO/.git/hooks:$WORK_DIR/.git/hooks:ro,z"
      -v "$REPO/.git/config:$WORK_DIR/.git/config:ro,z"
    )
  elif [[ -f "$REPO/.git" ]]; then
    echo "agentbox: warning: $REPO is a git worktree or submodule;" \
         "its git dir is outside the mount, so git will not work inside the container" >&2
  fi
}

# Per-project environment: <env dir>/<repo dir name>.env, if present, goes to
# the session as --env-file (podman format: KEY=VALUE per line, # comments,
# the value is taken literally, quotes included). Different projects can give
# the same variable (DB_CONN) different values, and only the box sees them:
# the agent on the host does not. The file stays on the host, outside the
# repo, so the agent cannot change what its next session starts with, and
# passwords in it never reach the project's git. Keyed by directory name:
# two repos with the same name share one file. The -e options of the session
# take precedence over --env-file, so it cannot override the proxy or agent
# setup.
session_env_file() {
  local file
  ENV_FILE_ARGS=()
  file="${AB_ENV_DIR:-$USER_ENV_DIR}/$(basename "$REPO").env"
  if [[ -f "$file" ]]; then
    ENV_FILE_ARGS=(--env-file "$file")
    echo "agentbox: env $file" >&2
  fi
}

# Agent-specific arguments: credentials, read-only config, skills, MCP.
# MCP servers come from the enabled modules (lib/mcp.sh) for both agents; the
# caller tokens are environment variables (MCP_SESSION_ARGS), which the
# generated configs reference as ${AB_MCP_TOKEN_<NAME>}.
session_agent_args() {
  AGENT_ARGS=(${MCP_SESSION_ARGS[@]+"${MCP_SESSION_ARGS[@]}"})
  [[ -n "$AGENT_VOL" ]] && AGENT_ARGS+=(-v "$AGENT_VOL:$AGENT_PREFIX:ro")
  AGENT_CMD=()
  case "$AGENT" in
    shell)
      # The arguments go to bash: none for an interactive shell, a script
      # path (tests/escape.sh) or -c '...'. Claude Code's MCP config is
      # there to try the sidecars with.
      AGENT_ARGS+=(
        --entrypoint "$AGENT_BIN"
        -v "$MCP_CLAUDE_JSON:/etc/agentbox/mcp.json:ro,z"
      )
      ;;
    claude)
      # ENABLE_CLAUDEAI_MCP_SERVERS=false  don't pull in connectors configured on
      #                                    claude.ai (Gmail, Slack, ...)
      # CLAUDE_CODE_DISABLE_ARTIFACT=1     no artifact reads from claudeusercontent.com
      # --mcp-config=FILE                  the modules' servers. The "=" form
      #                                    matters: with a space, the flag takes
      #                                    every following argument as a file.
      #                                    Subcommands (mcp list, setup-token)
      #                                    ignore it.
      AGENT_ARGS+=(
        -e ENABLE_CLAUDEAI_MCP_SERVERS=false
        -e CLAUDE_CODE_DISABLE_ARTIFACT=1
        --secret "claude_oauth,type=env,target=CLAUDE_CODE_OAUTH_TOKEN"
        -v "$MCP_CLAUDE_JSON:/etc/agentbox/mcp.json:ro,z"
      )
      AGENT_CMD=(--mcp-config=/etc/agentbox/mcp.json)
      if [[ -n "$SKILLS_SRC" ]]; then
        AGENT_ARGS+=(-v "$SKILLS_SRC:/home/node/.claude/skills:ro,z")
      fi
      # Personal instructions for every repo, shared with pi (agents/AGENTS.md).
      # From the host and read-only for the same reason as skills: written in
      # ab-claude-home by the agent, they would persist into every future session.
      if [[ -f "$USER_AGENTS_MD" ]]; then
        AGENT_ARGS+=(-v "$USER_AGENTS_MD:/home/node/.claude/CLAUDE.md:ro,z")
      fi
      if [[ -n "$STATUSLINE" ]]; then
        AGENT_ARGS+=(-v "$SCRIPT_DIR/claude/statusline.py:/home/node/.claude/statusline.py:ro,z")
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
      mkdir -p "$USER_PI_EXTENSIONS"
      AGENT_ARGS+=(
        --entrypoint "$AGENT_BIN"
        -e PI_OFFLINE=1
        -e PI_SKIP_VERSION_CHECK=1
        -e PI_TELEMETRY=0
        -v "$MCP_PI_JSON:/home/node/.pi/agent/mcp.json:ro,z"
        -v "$USER_PI_EXTENSIONS:/home/node/.pi/agent/extensions:ro,z"
      )
      # API-key mode only (openai_api_key secret exists): pi/models.json points
      # the openai provider at the ab-llm-openai sidecar. In subscription mode it
      # must NOT be mounted, or "Sign in with ChatGPT" requests would go to the
      # sidecar instead of api.openai.com.
      if podman secret inspect openai_api_key >/dev/null 2>&1 \
         && podman secret inspect llm_openai_caller >/dev/null 2>&1; then
        AGENT_ARGS+=(
          --secret "llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN"
          -v "$SCRIPT_DIR/pi/models.json:/home/node/.pi/agent/models.json:ro,z"
        )
      fi
      if [[ -n "$SKILLS_SRC" ]]; then
        AGENT_ARGS+=(-v "$SKILLS_SRC:/home/node/.pi/agent/skills:ro,z")
        # pi's own graphify skill over the shared (Claude Code) one; after the
        # skills mount, which provides the mount point.
        if [[ -d "$SKILLS_SRC/graphify" && -d "$GRAPHIFY_PI/graphify" ]]; then
          AGENT_ARGS+=(-v "$GRAPHIFY_PI/graphify:/home/node/.pi/agent/skills/graphify:ro,z")
        fi
      fi
      # Personal instructions, the same file Claude Code gets as CLAUDE.md. pi
      # reads AGENTS.md from its agent directory as global context.
      if [[ -f "$USER_AGENTS_MD" ]]; then
        AGENT_ARGS+=(-v "$USER_AGENTS_MD:/home/node/.pi/agent/AGENTS.md:ro,z")
      fi
      ;;
  esac
}

# SELinux labels for host directories used by sessions: lowercase ":z" (shared)
# on everything a session mounts from the host (repo, .git parts, skills, pi
# config). Uppercase ":Z" gives a directory a label private to ONE container,
# so a second session (Claude + pi in the same repo, or two sessions sharing
# skills/) relabels it and the first one loses access. Sidecar config files
# are each used by a single container and keep ":Z".
#
# Shared caches. Both agents mount the same two cache volumes, which hold no
# configuration and no credentials:
#   ab-cache -> ~/.cache  uv cache, Go build cache, per-repo virtualenvs
#   ab-go    -> ~/go      Go module cache and `go install` binaries
#
# Python virtualenv per repo, OUTSIDE the repo: uv puts the project env at
# UV_PROJECT_ENVIRONMENT instead of <repo>/.venv, so a .venv you use on the
# host is never overwritten with container paths, and vice versa. Kept in
# ab-cache, keyed by repo name + path hash, so both agents use the same env.
#
# Session: internal network only, no host credentials, read-only agent binary.
session_exec() {  # <agent arguments...>
  local venv_key no_proxy tty_flags
  venv_key="$(basename "$REPO")-$(printf '%s' "$REPO" | sha256sum | cut -c1-8)"
  no_proxy="$(IFS=,; echo "${MCP_NO_PROXY[*]+${MCP_NO_PROXY[*]},}${FORWARD_NAMES[*]+${FORWARD_NAMES[*]},}ab-llm-openai")"
  # Allocate a TTY only when attached to a terminal (keeps piping/scripts working).
  tty_flags=(-i)
  [[ -t 0 && -t 1 ]] && tty_flags+=(-t)
  exec podman run --rm "${tty_flags[@]}" \
    --name "ab-$AGENT-$$" \
    --network ab-internal \
    ${SERVICE_NET[@]+"${SERVICE_NET[@]}"} \
    ${FORWARD_NET[@]+"${FORWARD_NET[@]}"} \
    --userns="$USERNS" \
    --cap-drop=ALL --security-opt no-new-privileges \
    ${ENV_FILE_ARGS[@]+"${ENV_FILE_ARGS[@]}"} \
    -e HTTPS_PROXY=http://ab-egress:3128 \
    -e HTTP_PROXY=http://ab-egress:3128 \
    -e "NO_PROXY=$no_proxy" \
    -e "UV_PROJECT_ENVIRONMENT=/home/node/.cache/venvs/$venv_key" \
    ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
    ${TZ_ENV[@]+"${TZ_ENV[@]}"} \
    -v "$AGENT_HOME:/home/node" \
    -v ab-cache:/home/node/.cache \
    -v ab-go:/home/node/go \
    -v "$REPO:$WORK_DIR:z" \
    --workdir "$WORK_DIR" \
    ${GIT_MOUNTS[@]+"${GIT_MOUNTS[@]}"} \
    "${AGENT_ARGS[@]}" \
    "$IMAGE" ${AGENT_CMD[@]+"${AGENT_CMD[@]}"} "$@"
}
