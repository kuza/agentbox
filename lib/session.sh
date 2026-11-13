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

# Protect what git on the HOST executes or trusts in .git: hooks/, config
# (core.fsmonitor, core.sshCommand, ...) and modules/ (the submodules' own
# config and hooks) are read-only, so the agent cannot plant code that runs
# outside the container on your next git command. .git itself is a mount of
# its own, which cannot be renamed and replaced from inside.
#
# The rest of .git stays writable for commits, branches and worktrees, and
# that is not enough on its own: a .git/commondir file, or a worktree's .git
# file, can point host git at a directory with the agent's config and hooks.
# git-guard, a git wrapper on the host, refuses those, using the record
# session_git_record writes (README, Git on the host).
session_git_mounts() {
  GIT_MOUNTS=()
  session_git_record
  if ! grep -qs 'agentbox git-guard' "$(command -v git)"; then
    ab_warn "git on this host is not git-guard; a session can make" \
         "your next git command in this repo run its code (README, Git on the host)"
  fi
  if [[ -d "$REPO/.git" ]]; then
    mkdir -p "$REPO/.git/hooks" "$REPO/.git/modules"
    GIT_MOUNTS+=(
      -v "$REPO/.git:$WORK_DIR/.git:z"
      -v "$REPO/.git/hooks:$WORK_DIR/.git/hooks:ro,z"
      -v "$REPO/.git/config:$WORK_DIR/.git/config:ro,z"
      -v "$REPO/.git/modules:$WORK_DIR/.git/modules:ro,z"
    )
  elif [[ -f "$REPO/.git" ]]; then
    # Its "gitdir:" line tells git on the host where the repository is; the
    # agent must not point it at a directory with a config of its own.
    GIT_MOUNTS+=(-v "$REPO/.git:$WORK_DIR/.git:ro,z")
    ab_warn "$REPO is a git worktree or submodule;" \
         "its git dir is outside the mount, so git will not work inside the container"
  fi
}

# Records, for git-guard, the mounted directory and the git dir that git on
# the host may use for anything inside it, worked out from the paths before
# the session starts, without reading anything a session could have changed
# (such as a commondir file):
#   <repo>/.git            the repository's own .git
#   <main>/.git            a worktree or submodule (its read-only .git file),
#                          or a directory inside a repository: that one
#   none                   no repository: any that appears is the agent's
# One line per directory, "<dir><TAB><git dir>", in <AB_HOME>/mounted-repos.
session_git_record() {
  local expected="none" d gitdir list="$AB_HOME_DIR/mounted-repos"
  d="$REPO"
  while :; do
    if [[ -d "$d/.git" ]]; then
      expected="$d/.git"
      break
    elif [[ -f "$d/.git" ]]; then
      gitdir="$(sed -n 's/^gitdir: *//p' "$d/.git" | head -n1)"
      [[ "$gitdir" == /* ]] || gitdir="$d/$gitdir"
      gitdir="$(realpath -m -- "$gitdir")"
      # A worktree's git dir is <main>/.git/worktrees/<name>; a submodule's
      # is a repository of its own under <main>/.git/modules.
      if [[ "$(basename -- "$(dirname -- "$gitdir")")" == worktrees ]]; then
        expected="$(dirname -- "$(dirname -- "$gitdir")")"
      else
        expected="$gitdir"
      fi
      break
    fi
    [[ "$d" == / ]] && break
    d="$(dirname -- "$d")"
  done
  mkdir -p "$AB_HOME_DIR"
  {
    awk -F '\t' -v r="$REPO" '$1 != r' "$list" 2>/dev/null
    printf '%s\t%s\n' "$REPO" "$expected"
  } > "$list.tmp" && mv -f -- "$list.tmp" "$list"
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
  local f models agents_md=""
  [[ -f "$USER_AGENTS_MD" ]] && agents_md="$USER_AGENTS_MD"
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
      # Always mounted, an empty file when there is nothing to put there:
      # a single-file mount leaves an empty, root-owned mount point in the
      # home volume, which a later session without the mount would read and
      # fail on (session_optional_file).
      f="$(session_optional_file claude CLAUDE.md "$agents_md" "")" || exit 1
      AGENT_ARGS+=(-v "$f:/home/node/.claude/CLAUDE.md:ro,z")
      f="$(session_optional_file claude statusline.py "${STATUSLINE:+$SCRIPT_DIR/claude/statusline.py}" "")" || exit 1
      AGENT_ARGS+=(-v "$f:/home/node/.claude/statusline.py:ro,z")
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
      # API-key mode (openai_api_key secret exists): pi/models.json points the
      # openai provider at the ab-llm-openai sidecar. In subscription mode
      # pi's own providers must stay, or "Sign in with ChatGPT" requests would
      # go to the sidecar: a models.json without overrides.
      models=""
      if secret_exists openai_api_key && secret_exists llm_openai_caller; then
        models="$SCRIPT_DIR/pi/models.json"
        AGENT_ARGS+=(--secret "llm_openai_caller,type=env,target=OPENAI_CALLER_TOKEN")
      fi
      f="$(session_optional_file pi models.json "$models" '{ "providers": {} }')" || exit 1
      AGENT_ARGS+=(-v "$f:/home/node/.pi/agent/models.json:ro,z")
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
      f="$(session_optional_file pi AGENTS.md "$agents_md" "")" || exit 1
      AGENT_ARGS+=(-v "$f:/home/node/.pi/agent/AGENTS.md:ro,z")
      ;;
  esac
}

# The file to mount at a path that is always mounted: <file> if there is
# one (your AGENTS.md is mounted as it is; a file of agentbox's code as a
# copy, see cache_copy), else a copy of <fallback> text. Mounted always,
# because a single-file mount leaves an empty, root-owned mount point in the
# agent's home volume: a later session without the mount found it in place
# of the file and failed on it (pi: "EACCES ... models.json"). 1 when the
# file cannot be made.
session_optional_file() {  # <agent> <name> <file or ""> <fallback text>
  if [[ -z "$3" ]]; then
    cache_text "session/$1" "$2.none" "$4"
  elif [[ "$3" == "$SCRIPT_DIR"/* ]]; then
    cache_copy "session/$1" "$3" "$2"
  else
    # The caller checked that it is there.
    printf '%s\n' "$3"
  fi
}

# An agent that stops or crashes can keep terminal modes on. TERM_RESET
# turns off these modes:
# - mouse reports and focus events
# - bracketed paste and the alternate screen
# - application keys, the kitty keyboard protocol and modifyOtherKeys
# - the character set and the text attributes
# It also shows the cursor. It does not clear the screen, so the history of
# the terminal stays. It uses ?1047l, not ?1049l: ?1049l can move the cursor
# in tmux. term_reset uses the same condition as the -t flag of podman.
TERM_RESET=$'\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1004l\e[?2004l\e[?1047l\e[?1l\e>\e[<u\e[>4;0m\e(B\e[0m\e[?25h'
term_reset() {
  [[ -t 0 && -t 1 ]] && printf '%s' "$TERM_RESET"
  return 0
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
#
# --dns 127.0.0.1: podman's DNS (aardvark-dns) answers container names on the
# session's networks and forwards every other name to the container's DNS
# servers. Older aardvark-dns (podman 4.x) forwards them even on --internal
# networks, so external names resolved: a channel for data in the query
# names, without any TCP. Nothing listens on 127.0.0.1 where aardvark-dns
# runs, so external names fail; container names still resolve.
# Runs the session, then resets the terminal and exits with the status of
# podman. No exec: the reset must run after the container stops.
# Thus a SIGTERM to this shell does not stop podman. To stop a session,
# use `podman stop ab-<agent>-<PID>`. After the reset, session_end writes
# the log line and the message about a crash.
session_exec() {  # <agent arguments...>
  local venv_key no_proxy tty_flags rc=0 start name="ab-$AGENT-$$"
  venv_key="$(basename "$REPO")-$(printf '%s' "$REPO" | sha256sum | cut -c1-8)"
  no_proxy="$(IFS=,; echo "${MCP_NO_PROXY[*]+${MCP_NO_PROXY[*]},}${FORWARD_NAMES[*]+${FORWARD_NAMES[*]},}${SERVICE_NAMES[*]+${SERVICE_NAMES[*]},}ab-llm-openai")"
  # Allocate a TTY only when attached to a terminal (keeps piping/scripts working).
  tty_flags=(-i)
  [[ -t 0 && -t 1 ]] && tty_flags+=(-t)
  start="$(date +%s)"
  podman run --rm "${tty_flags[@]}" \
    --name "$name" \
    --label "agentbox.repo=$REPO" \
    --network ab-internal \
    --dns 127.0.0.1 \
    ${SERVICE_NET[@]+"${SERVICE_NET[@]}"} \
    ${FORWARD_NET[@]+"${FORWARD_NET[@]}"} \
    ${TRIVY_ARGS[@]+"${TRIVY_ARGS[@]}"} \
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
    "$IMAGE" ${AGENT_CMD[@]+"${AGENT_CMD[@]}"} "$@" || rc=$?
  term_reset
  session_end "$name" "$start" "$rc" || true
  exit "$rc"
}

# The end of a session. session_end writes one line to the session log:
#   <start> <end> <container> <agent> exit=<status>[ (SIG<name>)] <repository>
# The times are local times with the offset. The repository path is the
# last field, as it is, so that spaces and other letters stay readable.
# session_end replaces a newline or a carriage return in the path with
# "?", so that each session stays on one line. After a crash (134, 139)
# or a SIGKILL (137), session_end shows on stderr where to look further.
# The --since time of these commands has no offset: all versions of
# systemd read the local time in this form.
session_end() {  # <container> <start time, seconds since the epoch> <exit status>
  local name="$1" start_s="$2" rc="$3" sig="" start end since repo
  (( rc > 128 )) && sig="$(kill -l "$(( rc - 128 ))" 2>/dev/null)" && sig="SIG$sig"
  start="$(date -d "@$start_s" --iso-8601=seconds 2>/dev/null)"
  end="$(date --iso-8601=seconds 2>/dev/null)"
  repo="${REPO//[$'\n\r']/?}"
  session_log "$start $end $name $AGENT exit=$rc${sig:+ ($sig)} $repo" || true
  since="$(date -d "@$start_s" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  case "$rc" in
    134|139)
      echo "agentbox: the agent crashed (exit $rc${sig:+, $sig}). To see the core dump, run:" >&2
      echo "  coredumpctl list --since \"$since\"" >&2 ;;
    137)
      echo "agentbox: SIGKILL stopped the agent (exit $rc). Maybe the kernel stopped it for lack of memory," >&2
      echo "or podman kill or podman stop (after its timeout) stopped it. To find the messages of the OOM killer, run:" >&2
      echo "  journalctl -k --since \"$since\" | grep -i oom" >&2 ;;
  esac
  return 0
}

# Appends <line> to <cache>/agentbox/sessions.log. The log keeps the last
# SESSION_LOG_LINES lines. A lock stops two sessions that end at the same
# time from losing a line. Without the lock, session_log only appends the
# line. Errors do not stop the caller: the log is only a record.
SESSION_LOG_LINES=1000
session_log() {  # <line>
  local log="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sessions.log" lock="" locked="" n
  { mkdir -p -- "${log%/*}" && exec {lock}>> "$log.lock"; } 2>/dev/null || lock=""
  [[ -n "$lock" ]] && flock "$lock" 2>/dev/null && locked=1
  { printf '%s\n' "$1" >> "$log"; } 2>/dev/null
  if [[ -n "$locked" ]]; then
    n="$(wc -l < "$log" 2>/dev/null)" || n=0
    if (( n > SESSION_LOG_LINES )); then
      { tail -n "$SESSION_LOG_LINES" -- "$log" > "$log.$$" && mv -f -- "$log.$$" "$log"; } 2>/dev/null ||
        rm -f -- "$log.$$"
    fi
  fi
  [[ -n "$lock" ]] && exec {lock}>&-
  return 0
}
