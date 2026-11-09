#!/usr/bin/env bash
# Tests for run.sh (with lib/ and mcp/), check-updates.sh and sync-skills.sh.
# No podman, network or registry needed: podman, curl and the remote git
# side are stand-ins (tests/stub/podman, fake curl, local repositories).
#
#   tests/run.sh            all tests
#   tests/run.sh mcp_       tests whose name starts with "mcp_"
#
# Each test runs in its own scratch directory with a copy of agentbox's code,
# never the real config.env or skills/. Needs bash 4+, git, and Python
# 3.11+ (tomllib) for the TOML reader (lib/toml.sh).
set -uo pipefail

# Nothing from the caller's environment may point the scripts at real files:
# agentbox's settings, sync-skills.sh's, and the XDG directories (with
# XDG_CONFIG_HOME set, AB_HOME would be the caller's own ~/.config/agentbox).
# Nor change what git does: agentbox's environment.d file switches
# core.fsmonitor off for the whole login session (GIT_CONFIG_*), which would
# stop the attacks the git-guard tests first run on plain git.
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(AB_|SKILLS_|XDG_|GIT_CONFIG)')

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentbox-tests.XXXXXX")"
# Installed versions are read-only (releases tests): writable again first.
trap 'chmod -R u+w -- "${WORK:?}" 2>/dev/null; rm -rf -- "${WORK:?}"' EXIT
# The host may have git-guard installed as its git: the tests run the real
# git, and put git-guard in front only where they test it.
mkdir -p "$WORK/realgit"
IFS=: read -ra path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [[ -n "$d" && -x "$d/git" && ! -d "$d/git" ]] || continue
  grep -qs 'agentbox git-guard' "$d/git" && continue
  ln -s "$d/git" "$WORK/realgit/git"
  break
done
[[ -e "$WORK/realgit/git" ]] || { echo "tests need git (besides git-guard) in PATH" >&2; exit 1; }
PATH="$WORK/realgit:$PATH"
FILTER="${1:-}"
PASSED=0; FAILED=0; FAILURES=()

# --- harness ----------------------------------------------------------------

# setup <test name>: T (scratch dir), AB (agentbox copy), STUB_DIR (podman
# state), REPO (a repo to mount). Writes a minimal config.env.
setup() {
  T="$WORK/$1"
  AB="$T/ab"
  STUB_DIR="$T/stub"
  REPO="$T/repo"
  CFG="$T/home/.config/agentbox"
  mkdir -p "$AB" "$CFG" "$STUB_DIR" "$T/bin" "$T/home" "$REPO/.git/hooks"
  touch "$REPO/.git/config"
  cp -R "$ROOT/run.sh" "$ROOT/pi.sh" "$ROOT/Containerfile" "$ROOT/Containerfile.squid" "$ROOT/lib" "$ROOT/mcp" "$ROOT/squid.conf" "$ROOT/egress.d" "$ROOT/skills.d" "$ROOT/pi-extensions.d" \
        "$ROOT/check-updates.sh" "$ROOT/sync-skills.sh" "$ROOT/sync-pi-extension.sh" "$AB/" 2>/dev/null
  # Files the copy could not read (a sidecar's private SELinux label on the
  # source, see README, Troubleshooting) get a placeholder.
  local f
  while IFS= read -r f; do
    [[ -f "$AB/${f#"$ROOT"/}" ]] || echo "# placeholder" > "$AB/${f#"$ROOT"/}"
  done < <(find "$ROOT/mcp" -type f -name '*.template')
  mkdir -p "$AB/claude" "$AB/pi"
  cp "$ROOT/pi/llm-openai.conf.template" "$ROOT/pi/models.json" "$AB/pi/" 2>/dev/null || true
  cp "$ROOT/claude/statusline.py" "$AB/claude/" 2>/dev/null || true
  cp "$ROOT/tests/stub/podman" "$T/bin/podman"
  chmod +x "$T/bin/podman"
  # Never the real systemd: tests on a host must not stop its user
  # services. In bin/ with the podman stub, and alone in sysbin/ for the
  # agentbox command (ab_cmd), which runs the real podman.
  mkdir -p "$T/sysbin"
  cp "$ROOT/tests/stub/systemctl" "$T/sysbin/systemctl"
  chmod +x "$T/sysbin/systemctl"
  ln -s systemctl "$T/sysbin/systemd-run"
  ln -s ../sysbin/systemctl "$T/bin/systemctl"
  ln -s ../sysbin/systemctl "$T/bin/systemd-run"
  printf '%s\n' claude_oauth > "$STUB_DIR/secrets"
  : > "$CFG/config.env"
  export STUB_DIR
}

config() { printf '%s\n' "$@" >> "$CFG/config.env"; }
secrets() { printf '%s\n' "$@" >> "$STUB_DIR/secrets"; }

# ab_run [env...] -- [run.sh args...]: run.sh with the stub; output in $T/out,
# exit status in RC.
ab_run() {
  local envs=()
  while (( $# )) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  : > "$STUB_DIR/calls"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" \
      AB_CHECK_UPDATES=0 ${envs[@]+"${envs[@]}"} \
      bash "$AB/run.sh" "$REPO" "$@" > "$T/out" 2>&1 < /dev/null
  RC=$?
}

# ab_run_repo <dir>: run.sh with <dir> as the repo.
ab_run_repo() {
  : > "$STUB_DIR/calls"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_CHECK_UPDATES=0 \
      bash "$AB/run.sh" "$1" > "$T/out" 2>&1 < /dev/null
  RC=$?
}

# The session's podman run command, one argument per line.
session_args() {
  grep -E '^podman run --rm -i' "$STUB_DIR/calls" | tail -1 | tr ' ' '\n'
}
started() { awk '{ print $1 }' "$STUB_DIR/running" | sort | paste -sd' ' -; }
cache() { echo "$T/home/.cache/agentbox/$1"; }
source_value() { sed -n "s/^$2=//p" "$1" | tail -n1; }

fail() { CURRENT_OK=0; echo "    FAIL: $*"; }
assert_rc() { [[ "$RC" == "$1" ]] || fail "exit status $RC, expected $1"$'\n'"$(sed 's/^/      | /' "$T/out")"; }
assert_out() { grep -qE -- "$1" "$T/out" || fail "output lacks /$1/"$'\n'"$(sed 's/^/      | /' "$T/out")"; }
assert_no_out() { ! grep -qE -- "$1" "$T/out" || fail "output has /$1/"; }
assert_file_has() { grep -qE -- "$2" "$1" 2>/dev/null || fail "$(basename "$1") lacks /$2/"; }
# assert_skipped <module>: the start went on, without that MCP module.
assert_skipped() {
  assert_rc 0
  assert_out "MCP module '$1' left out of this session"
  grep -q "\"$1\"" "$T/home/.cache/agentbox/mcp-claude.json" && fail "$1 still in the agents' MCP config"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "the session did not start"
  return 0
}
assert_file_lacks() { ! grep -qE -- "$2" "$1" 2>/dev/null || fail "$(basename "$1") has /$2/"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "got '$1', expected '$2'${3:+ ($3)}"; }
assert_json() {
  command -v python3 >/dev/null || return 0
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null || fail "$(basename "$1") is not valid JSON"
}
json_keys() {  # <file>: mcpServers keys, space-separated
  python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["mcpServers"]))' "$1"
}

run_test() {
  local name="$1"
  [[ -n "$FILTER" && "${name#test_}" != "${FILTER#test_}"* ]] && return
  CURRENT_OK=1
  echo "  $name"
  ( "$name" ) > "$WORK/$name.log" 2>&1
  cat "$WORK/$name.log"
  if grep -q '^    FAIL' "$WORK/$name.log"; then
    FAILED=$((FAILED + 1)); FAILURES+=("$name")
  else
    PASSED=$((PASSED + 1))
  fi
}

# --- run.sh: MCP modules ----------------------------------------------------

test_mcp_default_set() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana graylog github" "GRAFANA_URL=https://grafana.example/" "GRAYLOG_URL=https://graylog.example/api"
  secrets grafana_sa graylog_basic github_pat
  ab_run -- -p "fix the test"
  assert_rc 0
  assert_eq "$(started)" "ab-egress ab-mcp-github ab-mcp-github-srv ab-mcp-grafana ab-mcp-graylog" "sidecars"
  assert_out "created secret grafana_mcp_caller"
  assert_out "created secret github_mcp_caller"
  local args; args="$(session_args)"
  grep -qx 'grafana_mcp_caller,type=env,target=AB_MCP_TOKEN_GRAFANA' <<<"$args" || fail "grafana token not passed"
  grep -qx 'github_mcp_caller,type=env,target=AB_MCP_TOKEN_GITHUB' <<<"$args" || fail "github token not passed"
  grep -qx 'NO_PROXY=ab-mcp-grafana,ab-mcp-graylog,ab-mcp-github,ab-llm-openai' <<<"$args" || fail "NO_PROXY: $(grep NO_PROXY <<<"$args")"
  # --mcp-config= right after the image, the user's arguments untouched after it.
  grep -qE '^podman run --rm -i .* localhost/agentbox --mcp-config=/etc/agentbox/mcp.json -p fix the test$' "$STUB_DIR/calls" \
    || fail "session command tail: $(grep -o 'localhost/agentbox.*' "$STUB_DIR/calls" | tail -1)"
  # Module settings reach the sidecars, normalized.
  grep -q 'GRAFANA_URL=https://grafana.example ' "$STUB_DIR/calls" || fail "GRAFANA_URL not normalized"
  grep -q 'GRAYLOG_URL=https://graylog.example ' "$STUB_DIR/calls" || fail "GRAYLOG_URL not normalized"
  assert_json "$(cache mcp-claude.json)"
  assert_json "$(cache mcp-pi.json)"
  assert_file_has "$(cache mcp-claude.json)" '"Bearer \$\{AB_MCP_TOKEN_GRAFANA\}"'
  assert_file_has "$(cache mcp-claude.json)" '"type": "http"'
  assert_file_has "$(cache squid-allow.conf)" '^acl allowed dstdomain mcp.context7.com$'
  if command -v python3 >/dev/null; then
    assert_eq "$(json_keys "$(cache mcp-claude.json)")" "context7 grafana graylog github" "claude servers"
  fi
}

test_mcp_pi_gets_same_servers() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana" "GRAFANA_URL=https://grafana.example"
  secrets grafana_sa
  ab_run AB_AGENT=pi --
  assert_rc 0
  grep -qE 'localhost/agentbox$' "$STUB_DIR/calls" || fail "pi must get no --mcp-config"
  session_args | grep -qx -- "$(cache mcp-pi.json):/home/node/.pi/agent/mcp.json:ro,z" || fail "pi mcp.json not mounted"
  session_args | grep -qx -- "$CFG/pi-extensions:/home/node/.pi/agent/extensions:ro,z" || fail "pi extensions not mounted from your files"
  [[ -d "$CFG/pi-extensions" ]] || fail "pi-extensions not created"
  assert_file_has "$(cache mcp-pi.json)" '"description": "Grafana'
  if command -v python3 >/dev/null; then
    assert_eq "$(json_keys "$(cache mcp-pi.json)")" "context7 grafana" "pi servers"
  fi
}

test_mcp_empty_list_context7_only() {
  setup "${FUNCNAME[0]}"
  ab_run --
  assert_rc 0
  assert_eq "$(started)" "ab-egress" "sidecars"
  session_args | grep -q '^--secret$' && session_args | grep -q 'AB_MCP_TOKEN' && fail "no caller tokens expected"
  session_args | grep -qx 'NO_PROXY=ab-llm-openai' || fail "NO_PROXY: $(session_args | grep NO_PROXY)"
  assert_json "$(cache mcp-claude.json)"
  if command -v python3 >/dev/null; then
    assert_eq "$(json_keys "$(cache mcp-claude.json)")" "context7"
  fi
}

test_mcp_missing_secret() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=graylog grafana" "GRAYLOG_URL=https://graylog.example" "GRAFANA_URL=https://g.example"
  secrets grafana_sa
  ab_run --
  assert_skipped graylog
  assert_out "graylog' left out of this session: missing podman secrets graylog_basic"
  grep -q '"grafana"' "$T/home/.cache/agentbox/mcp-claude.json" || fail "the other module left out too"
  run_line ab-mcp-graylog && fail "graylog's sidecar started"
  # A secret deleted to take the access away: the running sidecar goes too.
  secrets graylog_basic
  ab_run --
  assert_rc 0
  run_line ab-mcp-graylog >/dev/null || fail "graylog not started with its secret"
  sed -i '/^graylog_basic$/d' "$STUB_DIR/secrets"
  ab_run --
  assert_skipped graylog
  grep -q '^podman rm -f -v ab-mcp-graylog$' "$STUB_DIR/calls" || fail "sidecar kept serving the deleted secret"
  return 0
}

test_mcp_failed_start_skips_that_module_only() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=woodpecker grafana" "WOODPECKER_URL=ci.example" "GRAFANA_URL=https://g.example"
  secrets woodpecker_token grafana_sa
  ab_run --
  assert_skipped woodpecker
  assert_out "MCP module 'woodpecker' left out of this session: WOODPECKER_URL must be an http"
  run_line ab-mcp-grafana >/dev/null || fail "the other module's sidecar not started"
  grep -q '"grafana"' "$T/home/.cache/agentbox/mcp-claude.json" || fail "the other module left out too"
  grep -q '"woodpecker"' "$T/home/.cache/agentbox/mcp-pi.json" && fail "pi still gets woodpecker"
  session_args | grep -q 'AB_MCP_TOKEN_WOODPECKER' && fail "the session still gets woodpecker's caller token"
  # Once running, a module skipped by a later start keeps its sidecars for
  # the sessions using them...
  sed -i 's#^WOODPECKER_URL=.*#WOODPECKER_URL=https://ci.example#' "$CFG/config.env"
  ab_run --
  assert_rc 0
  run_line ab-mcp-woodpecker-srv >/dev/null || fail "woodpecker not started once fixed"
  config "WOODPECKER_CA=$T/missing-ca.pem"
  ab_run --
  assert_skipped woodpecker
  grep -q '^podman rm -f.* ab-mcp-woodpecker' "$STUB_DIR/calls" && fail "open sessions lost woodpecker"
  [[ " $(started) " == *" ab-mcp-woodpecker-srv "* ]] || fail "woodpecker's server stopped"
  sed -i '/^WOODPECKER_CA=/d' "$CFG/config.env"
  # ...unless access must go: a setting that does not check out (mcp_check),
  # as for an emptied one...
  sed -i 's#^WOODPECKER_URL=.*#WOODPECKER_URL=ci.example#' "$CFG/config.env"
  ab_run --
  assert_skipped woodpecker
  grep -qx 'podman rm -f -v ab-mcp-woodpecker-srv' "$STUB_DIR/calls" || fail "kept for a setting that does not check out"
  # ...or the module says so: a network with a way out.
  sed -i 's#^WOODPECKER_URL=.*#WOODPECKER_URL=https://ci.example#' "$CFG/config.env"
  ab_run --
  run_line ab-mcp-woodpecker-srv >/dev/null || fail "woodpecker not started again"
  ab_run STUB_NET_INTERNAL=false --
  assert_skipped woodpecker
  grep -qx 'podman rm -f -v ab-mcp-woodpecker-srv' "$STUB_DIR/calls" || fail "left running on a network with a way out"
  grep -qx 'podman rm -f -v ab-mcp-woodpecker' "$STUB_DIR/calls" || fail "nginx left running"
  return 0
}

test_mcp_podman_error_is_the_reason() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=graylog" "GRAYLOG_URL=https://graylog.example"
  secrets graylog_basic
  ab_run STUB_RUN_FAIL=ab-mcp-graylog --
  assert_skipped graylog
  assert_out "graylog' left out of this session: could not start ab-mcp-graylog: stub: cannot start ab-mcp-graylog"
  # No "Error:" line: the last line it printed.
  ab_run STUB_RUN_FAIL=ab-mcp-graylog STUB_RUN_ERR="crun: executable file not found" --
  assert_out "graylog' left out of this session: could not start ab-mcp-graylog: crun: executable file not found"
}

test_warnings_named_again_at_a_terminal() {
  command -v script >/dev/null || return 0
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana"
  secrets grafana_sa
  tty_run 'n\n' --
  assert_rc 1
  assert_out "agentbox: this start warned:"
  assert_out "  - MCP module 'grafana' left out of this session: it needs GRAFANA_URL"
  assert_out "  - git on this host is not git-guard"
  assert_out "agentbox: not started"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" && fail "the session started on a no"
  tty_run '\n' --
  assert_rc 0
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "the session did not start on Enter"
  # AB_WARNINGS_ASK=0: printed, not asked.
  tty_run '' AB_WARNINGS_ASK=0 --
  assert_rc 0
  assert_no_out "start the session\?"
  # A warning from inside the container (agent_prepare_home) is listed too;
  # its script runs in the image, where there is no ab_warn.
  tty_run '\n' STUB_HIDDEN_FILE=.claude/CLAUDE.md --
  assert_rc 0
  assert_out "  - ~/.claude/CLAUDE.md in the volume is hidden"
  sed -n '/^agent_prepare_home()/,/^}/p' "$ROOT/lib/agent.sh" | sed -n "/--entrypoint sh/,/' sh /p" | grep -q ab_warn \
    && fail "ab_warn in the script that runs in the container"
  # An agent run with -p does not wait for an answer.
  tty_run '' -- -p 'a task'
  assert_rc 0
  assert_no_out "start the session\?"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "-p run did not start"
  # Without a terminal: no question, the session starts.
  ab_run --
  assert_skipped grafana
  assert_no_out "start the session\?"
  return 0
}

test_mcp_take_away_finds_its_own_by_mark() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/mcp.local/git" "$CFG/mcp.local/git-lab"
  cat > "$CFG/mcp.local/git/mcp.sh" <<'MOD'
MCP_URL="http://ab-mcp-git:8080/mcp"
mcp_start() {
  [[ -f "$AB_HOME_DIR/git.off" ]] && { ab_error "access taken away"; exit "$MCP_TAKE_AWAY"; }
  start_sidecar ab-mcp-git docker.io/library/nginx:alpine
}
MOD
  cat > "$CFG/mcp.local/git-lab/mcp.sh" <<'MOD'
MCP_URL="http://ab-mcp-git-lab:8080/mcp"
mcp_start() {
  start_sidecar ab-mcp-git-lab -v "$(sidecar_copy ab-mcp-git-lab "$MCP_DIR/mcp.sh"):/x:ro,Z" docker.io/library/nginx:alpine
}
MOD
  config "AB_MCP=git-lab git"
  ab_run --
  assert_rc 0
  assert_eq "$(started)" "ab-egress ab-mcp-git ab-mcp-git-lab" "sidecars"
  run_line ab-mcp-git | grep -q -- '--label agentbox.module=git ' || fail "git's sidecar not marked"
  touch "$CFG/git.off"
  ab_run --
  assert_skipped git
  assert_out "MCP module 'git' left out of this session: access taken away"
  grep -qx 'podman rm -f -v ab-mcp-git' "$STUB_DIR/calls" || fail "git's sidecar kept"
  grep -q 'podman rm -f -v ab-mcp-git-lab' "$STUB_DIR/calls" && fail "git-lab's sidecar removed for git"
  [[ -d "$T/home/.cache/agentbox/sidecars/ab-mcp-git-lab" ]] || fail "git-lab's copies removed for git"
  grep -q '"git-lab"' "$T/home/.cache/agentbox/mcp-claude.json" || fail "git-lab left out"
  return 0
}

test_mcp_bb4() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=bb4" "BB4_URL=http://browser.example.internal:5101/" "BB4_USER=octo-cat"
  # Without the lock file nothing is built: left out, with how to make it.
  rm -f "$AB/mcp/bb4/devtools/package-lock.json"
  ab_run --
  assert_skipped bb4
  assert_out "package-lock.json is missing: in a clone, run"
  echo '{"lockfileVersion": 3}' > "$AB/mcp/bb4/devtools/package-lock.json"
  # An image from another lock file: built anew.
  echo "localhost/agentbox-bb4-devtools old" >> "$STUB_DIR/image_labels"
  ab_run --
  assert_rc 0
  local j="$T/home/.cache/agentbox/mcp-claude.json" l
  # Two servers: bb4 remote, through squid, without the caller token;
  # bb4-devtools through nginx, with it.
  grep -q '"bb4": { "type": "http", "url": "http://browser.example.internal:5101/u/octo-cat/mcp" }' "$j" \
    || fail "bb4 not registered: $(cat "$j")"
  grep -q '"bb4-devtools": { "type": "http", "url": "http://ab-mcp-bb4:8080/mcp", "headers": { "Authorization": "Bearer ${AB_MCP_TOKEN_BB4}" } }' "$j" \
    || fail "bb4-devtools not registered: $(cat "$j")"
  grep -q '"bb4-devtools"' "$T/home/.cache/agentbox/mcp-pi.json" || fail "pi lacks bb4-devtools"
  session_args | grep -qx 'bb4_mcp_caller,type=env,target=AB_MCP_TOKEN_BB4' || fail "caller token not passed"
  assert_file_has "$T/home/.cache/agentbox/squid-allow.conf" '^acl ab_host_[0-9]+ dstdomain browser.example.internal$'
  assert_file_has "$T/home/.cache/agentbox/squid-allow.conf" '^acl ab_port_[0-9]+ port 5101$'
  assert_out "warning: BB4 IS ON: THE AGENT DRIVES A BROWSER THAT REACHES THE WHOLE INTERNET"
  assert_eq "$(started)" "ab-egress ab-mcp-bb4 ab-mcp-bb4-devtools" "sidecars"
  grep "^podman build" "$STUB_DIR/calls" | grep -q -- "-t localhost/agentbox-bb4-devtools -f .*/mcp/bb4/devtools/Containerfile .*/mcp/bb4/devtools$" \
    || fail "devtools image not built"
  l="$(run_line ab-mcp-bb4-devtools)"
  [[ "$l" == *"--network ab-egress --secret bb4_bridge_key localhost/agentbox-bb4-devtools "* ]] || fail "devtools sidecar: $l"
  [[ "$l" == *"--stdio chrome-devtools-mcp --wsEndpoint=ws://browser.example.internal:5100/u/octo-cat/devtools/browser --no-usage-statistics --no-performance-crux "* ]] \
    || fail "devtools command: $l"
  [[ "$l" == *"--apiKeyFile /run/secrets/bb4_bridge_key --logLevel none" ]] || fail "devtools key: $l"
  l="$(run_line ab-mcp-bb4)"
  [[ "$l" == *"--network ab-internal --network ab-egress "* ]] || fail "nginx networks: $l"
  [[ "$l" == *"bb4_mcp_caller,type=env,target=BB4_CALLER_TOKEN"* && "$l" == *"bb4_bridge_key,type=env,target=BB4_BRIDGE_KEY"* ]] \
    || fail "nginx secrets: $l"
  assert_file_has "$ROOT/mcp/bb4/nginx.conf.template" 'proxy_pass http://ab-mcp-bb4-devtools:8000/mcp;'
  # A host without a dot still goes through squid, not NO_PROXY.
  ab_run BB4_URL=http://browser:5101 --
  assert_rc 0
  session_args | grep -q 'NO_PROXY=.*browser' && fail "remote bb4 host in NO_PROXY"
  session_args | grep -q 'NO_PROXY=.*ab-mcp-bb4' || fail "the sidecar not in NO_PROXY"
  # Built once; another port, https: wss on that port.
  ab_run BB4_DEVTOOLS_PORT=6100 BB4_URL=https://browser.example.internal --
  assert_rc 0
  grep -q '^podman build' "$STUB_DIR/calls" && fail "built again without a change"
  run_line ab-mcp-bb4-devtools | grep -q -- '--wsEndpoint=wss://browser.example.internal:6100/u/octo-cat/' || fail "wss: $(run_line ab-mcp-bb4-devtools)"
  # The server's URL with a path, an odd host or port, a user name that is
  # not one, a port that is not: left out, nothing added to squid.
  local bad
  for bad in "BB4_URL=http://browser.example.internal:5101/u/x" "BB4_URL=http://a..b:5101" "BB4_URL=http://browser.example.internal:05101" \
             "BB4_URL=http://browser.example.internal:99999" "BB4_USER=a/b" "BB4_DEVTOOLS_PORT=x"; do
    : > "$CFG/config.env"
    config "AB_MCP=bb4" "BB4_URL=http://browser.example.internal:5101" "BB4_USER=octo-cat" "$bad"
    [[ "$bad" == BB4_DEVTOOLS_PORT=* ]] || sed -i "0,/^${bad%%=*}=/{/^${bad%%=*}=/d}" "$CFG/config.env"
    printf 'ab-mcp-bb4-devtools x\n' >> "$STUB_DIR/running"
    ab_run --
    assert_skipped bb4
    # Settings that do not check out take the old browser connection away.
    grep -qx 'podman rm -f -v ab-mcp-bb4-devtools' "$STUB_DIR/calls" || fail "$bad: old devtools sidecar kept"
    [[ "$bad" == BB4_DEVTOOLS_PORT=* ]] && continue
    grep -q 'browser.example.internal' "$T/home/.cache/agentbox/squid-allow.conf" && fail "$bad: host still in squid"
  done
  return 0
}

test_mcp_server_names_and_urls_checked() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/mcp.local/a" "$CFG/mcp.local/b" "$CFG/mcp.local/c"
  printf 'MCP_URL=https://a.example/mcp\nMCP_SERVERS=("shared|https://a.example/mcp|-|A")\n' > "$CFG/mcp.local/a/mcp.sh"
  printf 'MCP_URL=https://b.example/mcp\nMCP_SERVERS=("shared|https://b.example/mcp|-|B")\n' > "$CFG/mcp.local/b/mcp.sh"
  config "AB_MCP=a b"
  ab_run --
  assert_skipped b
  assert_out "MCP module 'b' left out of this session: its server 'shared' has the name of one of module 'a'"
  grep -q 'a.example' "$T/home/.cache/agentbox/mcp-claude.json" || fail "a left out"
  # A name is taken only by a module that is not left out for another
  # reason: b gets it once a lacks its setting.
  printf 'MCP_URL=https://a.example/mcp\nMCP_CONFIG=(A_URL)\nMCP_REQUIRED_CONFIG=(A_URL)\nMCP_SERVERS=("shared|https://a.example/mcp|-|A")\n' > "$CFG/mcp.local/a/mcp.sh"
  ab_run --
  assert_skipped a
  grep -q 'b.example' "$T/home/.cache/agentbox/mcp-claude.json" || fail "b left out for a skipped a"
  # A sidecar of a module of yours without a caller token: still reached
  # without the proxy.
  printf 'MCP_URL=http://ab-mcp-d:8080/mcp\n' > "$CFG/mcp.local/b/mcp.sh"
  ab_run --
  session_args | grep -q 'NO_PROXY=.*ab-mcp-d' || fail "own sidecar without a caller token sent through squid"
  # A malformed module is left out, not the whole start.
  printf 'MCP_URL="https://c.example/x|y"\n' > "$CFG/mcp.local/c/mcp.sh"
  : > "$CFG/config.env"; config "AB_MCP=c"
  ab_run --
  assert_skipped c
  assert_out "c' left out of this session: its MCP_URL has a |"
  printf 'MCP_SERVERS=("s|http://ab-mcp-c:8080/mcp|caller|C")\n' > "$CFG/mcp.local/c/mcp.sh"
  ab_run --
  assert_skipped c
  assert_out "its server 's' is marked caller, but its mcp.sh sets no MCP_CALLER_SECRET"
  printf 'MCP_SERVERS=("s|https://c.example/1|-|C" "s|https://c.example/2|-|C")\n' > "$CFG/mcp.local/c/mcp.sh"
  ab_run --
  assert_skipped c
  assert_out "its MCP_SERVERS has the server 's' twice"
  # One that does not parse is left out; its settings are no unknown keys.
  printf 'MCP_URL=https://c.example/mcp\nMCP_CONFIG=(C_URL C_X)\nif\n' > "$CFG/mcp.local/c/mcp.sh"
  config "C_X=1"
  ab_run --
  assert_skipped c
  assert_out "c' left out of this session: its mcp.sh does not parse"
  assert_no_out "unknown key 'C_X'"
  sed -i '/^C_X=/d' "$CFG/config.env"
  # A problem from mcp_check counts also when it returns non-zero.
  printf 'MCP_URL=https://c.example/mcp\nmcp_check() { echo "C is bad"; return 1; }\n' > "$CFG/mcp.local/c/mcp.sh"
  ab_run --
  assert_skipped c
  assert_out "c' left out of this session: C is bad"
  # A module whose last line is false still loads.
  printf 'MCP_URL=https://c.example/mcp\nMCP_EGRESS=(c.example)\n[[ -n "${NOPE:-}" ]] && X=1\n' > "$CFG/mcp.local/c/mcp.sh"
  ab_run --
  assert_rc 0
  grep -q 'c.example/mcp' "$T/home/.cache/agentbox/mcp-claude.json" || fail "a module ending in a false && left out"
  # A URL from the module's settings counts once they are read; emptied, its
  # sidecars go.
  printf 'MCP_CONFIG=(C_URL)\nMCP_URL="${C_URL:-}"\nMCP_EGRESS=(c.example)\n' > "$CFG/mcp.local/c/mcp.sh"
  config "C_URL=https://c.example/mcp"
  ab_run --
  assert_rc 0
  grep -q 'c.example/mcp' "$T/home/.cache/agentbox/mcp-claude.json" || fail "a URL from settings not taken"
  sed -i '/^C_URL=/d' "$CFG/config.env"
  printf 'ab-mcp-c x\n' >> "$STUB_DIR/running"
  ab_run --
  assert_skipped c
  grep -qx 'podman rm -f -v ab-mcp-c' "$STUB_DIR/calls" || fail "sidecar kept with its URL setting emptied"
  # The same for a server line of MCP_SERVERS.
  printf 'MCP_CONFIG=(C_URL)\nMCP_SERVERS=("s|${C_URL:-}|-|C")\n' > "$CFG/mcp.local/c/mcp.sh"
  printf 'ab-mcp-c x\n' >> "$STUB_DIR/running"
  ab_run --
  assert_skipped c
  assert_out "no URL for its server 's'"
  grep -qx 'podman rm -f -v ab-mcp-c' "$STUB_DIR/calls" || fail "sidecar kept with its server's URL setting emptied"
}

test_mcp_missing_setting() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana"
  secrets grafana_sa
  ab_run --
  assert_skipped grafana
  assert_out "grafana' left out of this session: it needs GRAFANA_URL"
}

test_mcp_unknown_module() {
  setup "${FUNCNAME[0]}"
  # A module of another version, or a typo: left out, the rest starts.
  config "AB_MCP=grafana jira" "GRAFANA_URL=https://g.example"
  secrets grafana_sa
  ab_run --
  assert_skipped jira
  assert_out "MCP module 'jira' left out of this session: this agentbox has no such module"
  grep -q '"grafana"' "$T/home/.cache/agentbox/mcp-claude.json" || fail "grafana left out too"
  # Its sidecars, of another version's sessions, stay: by their mark only,
  # not by name (a typo "jira" would keep an unmarked ab-mcp-jira-old).
  printf 'ab-mcp-jira x\nab-mcp-jira-old x\n' >> "$STUB_DIR/running"
  printf 'ab-mcp-jira agentbox.module=jira\n' >> "$STUB_DIR/labels"
  ab_run --
  grep -qx 'podman rm -f -v ab-mcp-jira' "$STUB_DIR/calls" && fail "another version's sidecar removed"
  grep -qx 'podman rm -f -v ab-mcp-jira-old' "$STUB_DIR/calls" || fail "an unmarked sidecar kept by its name"
  return 0
}

test_mcp_invalid_name() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=../etc"
  ab_run --
  assert_rc 2
  assert_out "invalid module name"
}

test_mcp_local_module_and_override() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/mcp.local/tracker" "$CFG/mcp.local/context7"
  printf '%s\n' 'MCP_DESCRIPTION="Tracker"' 'MCP_URL="https://mcp.tracker.example/mcp"' \
    'MCP_EGRESS=(mcp.tracker.example)' 'MCP_CONFIG=(TRACKER_SITE)' > "$CFG/mcp.local/tracker/mcp.sh"
  printf '%s\n' 'MCP_DESCRIPTION="Docs mirror"' 'MCP_URL="https://docs.internal.example/mcp"' \
    'MCP_EGRESS=(docs.internal.example)' > "$CFG/mcp.local/context7/mcp.sh"
  config "AB_MCP=tracker" "TRACKER_SITE=acme"
  ab_run --
  assert_rc 0
  assert_no_out "unknown key 'TRACKER_SITE'"
  assert_file_has "$(cache squid-allow.conf)" 'dstdomain mcp.tracker.example$'
  assert_file_has "$(cache squid-allow.conf)" 'dstdomain docs.internal.example$'
  assert_file_lacks "$(cache squid-allow.conf)" 'mcp.context7.com'
  assert_file_has "$(cache mcp-claude.json)" 'https://docs.internal.example/mcp'
}

test_mcp_config_keys_of_disabled_module_quiet() {
  setup "${FUNCNAME[0]}"
  # Settings of a module that is there but not enabled: kept, no warning.
  # A key that no module has: a warning (a typo).
  mkdir -p "$CFG/mcp.local/tracker"
  printf '%s\n' 'MCP_URL="https://t.example/mcp"' 'MCP_CONFIG=(TRACKER_SITE)' > "$CFG/mcp.local/tracker/mcp.sh"
  config "GRAFANA_URL=https://grafana.example" "BB4_URL=http://b.example:5101" "TRACKER_SITE=x" "NO_SUCH_KEY=1"
  ab_run --
  assert_rc 0
  assert_no_out "unknown key 'GRAFANA_URL'"
  assert_no_out "unknown key 'BB4_URL'"
  assert_no_out "unknown key 'TRACKER_SITE'"
  assert_out "unknown key 'NO_SUCH_KEY'"
  # A key with a space: not KEY=VALUE, and the start goes on.
  config "AB_MCP AB_EGRESS=x"
  ab_run --
  assert_rc 0
  assert_out "not KEY=VALUE, ignored"
  sed -i '/^AB_MCP AB_EGRESS=x$/d' "$CFG/config.env"
  # Only in config.env: in a repo's .conf, a module key still warns.
  mkdir -p "$CFG/env"
  echo "GRAFANA_URL=https://grafana.example" > "$CFG/env/repo.conf"
  ab_run --
  assert_out "repo.conf:1: unknown key 'GRAFANA_URL'"
  rm "$CFG/env/repo.conf"
  # A module of yours replaces the shared one of its name: its keys count,
  # not those of the shared one. A copy with a name that is not one adds
  # nothing.
  mkdir -p "$CFG/mcp.local/grafana" "$CFG/mcp.local/tracker.bak"
  printf '%s\n' 'MCP_URL="https://g.example/mcp"' 'MCP_CONFIG=(MY_G)' > "$CFG/mcp.local/grafana/mcp.sh"
  printf '%s\n' 'MCP_URL="https://t.example/mcp"' 'MCP_CONFIG=(NO_SUCH_KEY)' > "$CFG/mcp.local/tracker.bak/mcp.sh"
  ab_run --
  assert_out "unknown key 'GRAFANA_URL'"
  assert_out "unknown key 'NO_SUCH_KEY'"
}

test_mcp_egress_recreated_only_on_change() {
  setup "${FUNCNAME[0]}"
  ab_run --
  assert_rc 0
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" || fail "egress not started"
  ab_run --
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" && fail "egress recreated without a change"
  mkdir -p "$CFG/mcp.local/extra"
  printf '%s\n' 'MCP_URL="https://extra.example/mcp"' 'MCP_EGRESS=(extra.example)' > "$CFG/mcp.local/extra/mcp.sh"
  config "AB_MCP=extra"
  ab_run --
  grep -q '^podman rm -f -v ab-egress' "$STUB_DIR/calls" || fail "egress not recreated after the host list changed"
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" || fail "egress not started again"
}

test_mcp_old_registrations_passed_for_cleanup() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=github"
  secrets github_pat
  ab_run --
  assert_rc 0
  # The managed list (name and URL per line) goes to the home preparation.
  grep -q 'AB_MCP_MANAGED=context7 https://mcp.context7.com/mcp' "$STUB_DIR/calls" || fail "managed list missing"
  grep -q '^github http://ab-mcp-github:8080/mcp' "$STUB_DIR/calls" || fail "github not in the managed list"
}

test_mcp_upgrade_pulls_module_images() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana" "GRAFANA_URL=https://g.example"
  secrets grafana_sa
  ab_run AB_UPGRADE=1 --
  assert_rc 0
  grep -q '^podman pull -q docker.io/grafana/mcp-grafana:latest' "$STUB_DIR/calls" || fail "grafana image not pulled"
  grep -q '^podman pull -q ghcr.io/github/github-mcp-server' "$STUB_DIR/calls" && fail "github image pulled while disabled"
}

# --- run.sh: egress groups ---

test_egress_default_groups() {
  setup "${FUNCNAME[0]}"
  ab_run --
  assert_rc 0
  local f; f="$(cache squid-allow.conf)"
  assert_file_has "$f" '^acl allowed dstdomain api.anthropic.com$'
  assert_file_has "$f" '^acl allowed dstdomain pypi.org$'
  assert_file_has "$f" '^acl allowed dstdomain proxy.golang.org$'
  assert_file_has "$f" '^acl allowed dstdomain auth.openai.com$'
  assert_file_has "$f" '^acl allowed dstdomain mcp.context7.com$'
  assert_file_lacks "$f" 'github.com|storage.googleapis.com|chatgpt.com'
  grep -q 'squid-allow.conf:/etc/squid/agentbox-allow.conf:ro,Z' "$STUB_DIR/calls" || fail "include not mounted"
  # chatgpt (pi's legacy provider) only when listed.
  config "AB_EGRESS=anthropic openai chatgpt"
  ab_run --
  assert_rc 0
  assert_file_has "$(cache squid-allow.conf)" '^acl allowed dstdomain chatgpt.com$'
}

test_egress_listed_groups_local_override_and_ports() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/egress.local.d"
  printf '%s\n' '# test servers' 'hosts = [' '  "Data.S3.eu-central-1.amazonaws.com",' '  "minio.test:9000",  # MinIO' \
    '  ".internal.example",' ']' > "$CFG/egress.local.d/test.toml"
  printf '%s\n' 'hosts = ["mirror.example"]' > "$CFG/egress.local.d/pypi.toml"
  config "AB_EGRESS=anthropic pypi, gcs test gcs"
  ab_run --
  assert_rc 0
  local f; f="$(cache squid-allow.conf)"
  assert_file_has "$f" '^acl allowed dstdomain mirror.example$'
  assert_file_lacks "$f" 'pypi.org|golang|openai'
  assert_eq "$(grep -c 'storage.googleapis.com' "$f")" 1 "gcs listed twice"
  assert_file_has "$f" '^acl allowed dstdomain data.s3.eu-central-1.amazonaws.com$'
  assert_file_has "$f" '^acl allowed dstdomain .internal.example$'
  assert_file_has "$f" '^acl ab_host_1 dstdomain minio.test$'
  assert_file_has "$f" '^acl ab_port_1 port 9000$'
  assert_file_has "$f" '^http_access allow ab_host_1 ab_port_1$'
  assert_file_lacks "$f" 'dstdomain minio.test:9000'
}

test_egress_empty_list_mcp_hosts_only() {
  setup "${FUNCNAME[0]}"
  config "AB_EGRESS="
  ab_run AB_AGENT=pi --
  assert_rc 0
  assert_file_lacks "$(cache squid-allow.conf)" 'pypi.org|anthropic'
  assert_file_has "$(cache squid-allow.conf)" 'dstdomain mcp.context7.com$'
  # squid.conf refers to "allowed": it must be defined even with no hosts.
  mkdir -p "$CFG/mcp.local/context7"
  printf '%s\n' 'MCP_URL="http://docs-mirror:8080/mcp"' > "$CFG/mcp.local/context7/mcp.sh"
  ab_run AB_AGENT=pi --
  assert_rc 0
  assert_eq "$(grep -c '^acl allowed ' "$(cache squid-allow.conf)")" 1 "allowed acl lines"
  assert_file_has "$(cache squid-allow.conf)" '^acl allowed dstdomain .invalid$'
}

test_egress_agent_group_required() {
  setup "${FUNCNAME[0]}"
  config "AB_EGRESS=pypi go"
  ab_run --
  assert_rc 2
  assert_out "claude needs the egress group 'anthropic'"
  grep -q '^podman run -d' "$STUB_DIR/calls" && fail "sidecars started despite the error"
  ab_run AB_AGENT=pi --
  assert_rc 0
}

test_egress_errors() {
  setup "${FUNCNAME[0]}"
  config "AB_EGRESS=nope"
  ab_run --
  assert_rc 2
  assert_out "no group 'nope'"
  : > "$CFG/config.env"; config "AB_EGRESS=../x"
  ab_run --
  assert_rc 2
  assert_out "invalid group name"
  mkdir -p "$CFG/egress.local.d"
  printf '%s\n' '# a group' 'hosts = [' '  "ok.example",' '  "bad host; http_access allow all",' ']' > "$CFG/egress.local.d/bad.toml"
  : > "$CFG/config.env"; config "AB_EGRESS=bad"
  ab_run --
  assert_rc 2
  assert_out "bad.toml:2: 'hosts': an item of the list cannot hold a space"
  grep -q '^podman run -d' "$STUB_DIR/calls" && fail "sidecars started despite the error"
  : > "$CFG/config.env"
  local h
  for h in 'x.example:99999' 'x.example:0' 'x_y.example' '*.example' 'x.example:443/path'; do
    printf 'hosts = ["%s"]\n' "$h" > "$CFG/egress.local.d/bad.toml"
    config "AB_EGRESS=bad"
    ab_run --
    assert_rc 2
    assert_out "is not a host name"
  done
}

# A python3 in front of the interpreter that the reader uses (lib/toml.sh,
# toml_python) that writes each call to $T/python.log.
python_log_stub() {
  local p real=""
  for p in python3 python3.13 python3.12 python3.11; do
    if command -v "$p" >/dev/null && "$p" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
      real="$(command -v "$p")"
      break
    fi
  done
  [[ -n "$real" ]] || fail "no Python 3.11 or newer on the test host"
  printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$T/python.log" "$real" > "$T/bin/python3"
  chmod +x "$T/bin/python3"
}

test_egress_unchanged_start_runs_no_python() {
  setup "${FUNCNAME[0]}"
  python_log_stub
  ab_run --
  assert_rc 0
  [[ -s "$T/python.log" ]] || fail "the first start did not read the groups"
  : > "$T/python.log"
  ab_run --
  assert_rc 0
  [[ -s "$T/python.log" ]] && fail "a start with no changed file ran Python: $(cat "$T/python.log")"
  # A changed schema is a new reader version: the files are read again.
  echo '# changed' >> "$AB/lib/toml-schema/egress-group.toml"
  ab_run --
  assert_rc 0
  [[ -s "$T/python.log" ]] || fail "a changed schema did not run the reader again"
}

test_egress_start_without_python_311() {
  setup "${FUNCNAME[0]}"
  # Each Python that the reader looks for is too old: a stub in front of
  # the real one that exits 1.
  local p
  mkdir -p "$T/nopy"
  for p in python3 python3.13 python3.12 python3.11; do
    printf '#!/bin/sh\nexit 1\n' > "$T/nopy/$p"
    chmod +x "$T/nopy/$p"
  done
  ab_run "PATH=$T/bin:$T/nopy:$PATH" --
  assert_rc 2
  assert_out "agentbox needs Python 3.11 or newer"
  assert_out "apt install python3.11"
  grep -q '^podman run' "$STUB_DIR/calls" && fail "containers started without Python"
}

test_egress_recreated_when_groups_change() {
  setup "${FUNCNAME[0]}"
  ab_run --
  ab_run --
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" && fail "recreated without a change"
  config "AB_EGRESS=anthropic pypi"
  ab_run --
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" || fail "not recreated after AB_EGRESS changed"
}

# --- run.sh: the conversion of your files from v0.1.x ---

# A local group in the old form (one host per line) that replaces the
# shared pypi group.
old_pypi_group() {
  mkdir -p "$CFG/egress.local.d"
  printf '%s\n' '# my mirror' '' 'Mirror.example  # the index' '# files' 'files.mirror.example:8443' \
    > "$CFG/egress.local.d/pypi.conf"
}

test_convert_egress_group() {
  setup "${FUNCNAME[0]}"
  old_pypi_group
  local before; before="$(stat -c '%Y %s' "$CFG/egress.local.d/pypi.conf"; sha256sum < "$CFG/egress.local.d/pypi.conf")"
  ab_run --
  assert_rc 0
  assert_out "egress.local.d/pypi.conf -> pypi.toml"
  assert_out "converted.list"
  assert_out "remove its line"
  # Yours wins over the shared pypi.toml.
  local f; f="$(cache squid-allow.conf)"
  assert_file_has "$f" '^acl allowed dstdomain mirror.example$'
  assert_file_has "$f" '^acl ab_host_1 dstdomain files.mirror.example$'
  assert_file_lacks "$f" 'pypi.org'
  # The comments stay; the old file stays unchanged, for a rollback.
  assert_eq "$(cat "$CFG/egress.local.d/pypi.toml")" '# my mirror

hosts = [
  "Mirror.example",  # the index
  # files
  "files.mirror.example:8443",
]'
  assert_eq "$(stat -c '%Y %s' "$CFG/egress.local.d/pypi.conf"; sha256sum < "$CFG/egress.local.d/pypi.conf")" "$before" "old file"
  assert_eq "$(cat "$CFG/converted.list")" "$CFG/egress.local.d/pypi.conf"
  # The next start converts nothing.
  ab_run --
  assert_rc 0
  assert_no_out "converted"
}

test_convert_once_new_file_and_newer_old_file() {
  setup "${FUNCNAME[0]}"
  old_pypi_group
  ab_run --
  assert_rc 0
  # You remove the converted file: it is not converted again.
  rm "$CFG/egress.local.d/pypi.toml"
  printf '%s\n' 'corp.example' > "$CFG/egress.local.d/corp.conf"
  config "AB_EGRESS=anthropic pypi corp"
  ab_run --
  assert_rc 0
  [[ -e "$CFG/egress.local.d/pypi.toml" ]] && fail "pypi.conf converted a second time"
  # A new .conf is converted.
  assert_out "egress.local.d/corp.conf -> corp.toml"
  assert_no_out "pypi.conf ->"
  assert_file_has "$(cache squid-allow.conf)" '^acl allowed dstdomain corp.example$'
  assert_file_has "$(cache squid-allow.conf)" '^acl allowed dstdomain pypi.org$'
  # An old file changed after its conversion (after a rollback): a warning.
  touch -d '+1 minute' "$CFG/egress.local.d/corp.conf"
  ab_run --
  assert_rc 0
  assert_out "warning: .*egress.local.d/corp.conf is newer than .*egress.local.d/corp.toml"
  assert_no_out "converted"
  # A TOML file of yours was there first: the old file is kept, not
  # converted, and a newer old file gets no warning.
  printf '%s\n' 'hosts = ["mine.example"]' > "$CFG/egress.local.d/mine.toml"
  printf '%s\n' 'old.example' > "$CFG/egress.local.d/mine.conf"
  touch -d '+1 minute' "$CFG/egress.local.d/mine.conf"
  ab_run --
  assert_out "mine.conf: not converted, .*mine.toml is there"
  ab_run --
  assert_no_out "mine.conf is newer"
  # A converted group whose TOML file you removed: the start names the list.
  rm "$CFG/egress.local.d/corp.toml"
  ab_run --
  assert_rc 2
  assert_out "corp.conf was converted before. To convert it again, remove its line from .*converted.list"
}

test_convert_broken_old_file_warns() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/egress.local.d"
  # Broken: two hosts on one line. A group that no setting uses does not
  # stop the start.
  printf '%s\n' '# a group' 'ok.example' 'one.example two.example' > "$CFG/egress.local.d/bad.conf"
  # Not UTF-8 and a control character, both in comments only: converted.
  printf '# Z\xfcrich mirror\nz.example  # note\x1b[0m\n' > "$CFG/egress.local.d/latin.conf"
  ab_run --
  assert_rc 0
  assert_out "warning: .*bad.conf:3: one host per line"
  assert_out "did not convert .*bad.conf"
  assert_out "egress.local.d/latin.conf -> latin.toml"
  [[ -e "$CFG/egress.local.d/bad.toml" ]] && fail "a broken file converted"
  grep -q 'bad.conf' "$CFG/converted.list" && fail "a broken file listed"
  # Enabled, the group is not there: the start stops and names the old file.
  config "AB_EGRESS=bad latin"
  ab_run --
  assert_rc 2
  assert_out "bad.conf was not converted to TOML \\(see the warning above\\)"
  grep -q '^podman run' "$STUB_DIR/calls" && fail "containers started without the group"
  # agentbox setup converts too, and shows the corrected file.
  cp "$ROOT/agentbox" "$AB/"
  printf '%s\n' '# a group' 'ok.example' > "$CFG/egress.local.d/bad.conf"
  setup_run "q\n"
  assert_out "egress.local.d/bad.conf -> bad.toml"
  assert_out '\[x\] bad +\(yours\) ok.example$'
}

# Two starts at the same time. The writer of the first start is slow (a
# python3 that waits), so the first start holds the lock for a while. The
# second start waits for the lock, then finds the file in the list.
test_convert_two_starts_one_converts() {
  setup "${FUNCNAME[0]}"
  python_log_stub
  # The writer marks that it runs (the first start holds the lock), then waits.
  sed -i "2i case \"\$*\" in *toml-writer.py*) touch '$T/writing'; sleep 1 ;; esac" "$T/bin/python3"
  old_pypi_group
  ab_run -- &
  local first=$!
  local i
  for i in $(seq 50); do [[ -e "$T/writing" ]] && break; sleep 0.1; done
  [[ -e "$T/writing" ]] || fail "the first start did not reach the writer"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_CHECK_UPDATES=0 \
    bash "$AB/run.sh" "$REPO" > "$T/out.second" 2>&1 < /dev/null
  wait "$first"
  assert_eq "$(cat "$T/out" "$T/out.second" | grep -c 'pypi.conf -> pypi.toml')" 1 "conversions"
  assert_eq "$(grep -c 'toml-writer.py' "$T/python.log")" 1 "writer runs"
  assert_eq "$(grep -c . "$CFG/converted.list")" 1 "lines in the list"
}

# The writer for KEY=VALUE files, the form of the settings and the old
# sources. The test uses the kind of the tests (tests/toml/flat.schema.toml).
# Each value gets the type of its key in the schema. A key that the schema
# does not know becomes a comment. The written file reads back the same.
test_convert_keys_by_type_and_unknown_key() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/tests/toml/flat.schema.toml" "$AB/lib/toml-schema/flat.toml"
  printf '%s\n' '# my source' 'NAME=a"b\c # note' 'PREFIX=' "COUNT='007'" 'export ON=1' 'OFF=0' 'ITEMS=x, y z' \
    'TYPO=1' 'NAME=second' 'nAME=third' 'not a setting' > "$T/old.conf"
  (
    HOME="$T/home" SCRIPT_DIR="$AB" XDG_CACHE_HOME="$T/home/.cache"
    for lib in paths config toml convert; do
      # shellcheck source=/dev/null
      source "$AB/lib/$lib.sh"
    done
    CONVERT_TODO=("flat keys $T/old.conf")
    convert_run
  ) > "$T/out" 2>&1
  assert_out "warning: .*old.conf:8: unknown key 'TYPO', kept as a comment"
  assert_out "warning: .*old.conf:9: second time 'NAME', kept as a comment"
  # load_config knows a key only in its own case, and warns on other lines.
  assert_out "warning: .*old.conf:10: unknown key 'nAME', kept as a comment"
  assert_out "warning: .*old.conf:11: not KEY=VALUE, kept as a comment"
  assert_out "old.conf -> old.toml"
  assert_eq "$(cat "$T/old.toml")" '# my source
name = "a\"b\\c"  # note
prefix = ""
count = 7
on = true
off = false
items = ["x", "y", "z"]
# TYPO=1
# NAME=second
# nAME=third
# not a setting'
  assert_eq "$(toml_case flat "$T/old.toml")" 'count 4 4 7
items 7 7 x y z
name 2 2 a"b\c
off 6 6 0
on 5 5 1
prefix 3 3 '
}

# --- run.sh: forwards ---

# The hash in tabularis_bridge_dir (mcp/tabularis/mcp.sh), for the tests.
bridge_hash() {
  cat "$AB/mcp/tabularis/bridge/package.json" "$AB/mcp/tabularis/bridge/package-lock.json" | sha256sum | cut -c1-16
}
fwd_key() { printf '%s' "$REPO" | sha256sum | cut -c1-8; }
run_line() { grep "^podman run -d --replace --name $1 " "$STUB_DIR/calls"; }

test_forward_global_and_repo() {
  setup "${FUNCNAME[0]}"
  config "AB_FORWARD=db=DB.test.example:5432"
  mkdir -p "$CFG/env"
  printf '%s\n' '# test servers of this repo' 'AB_FORWARD=mq=mq.test.example:5672, web=web.test.example:80' > "$CFG/env/repo.conf"
  ab_run --
  assert_rc 0
  local k; k="$(fwd_key)"
  assert_out "repo config $CFG/env/repo.conf"
  assert_eq "$(started | tr ' ' '\n' | grep '^ab-fwd' | paste -sd' ' -)" \
    "$(printf '%s\n' "ab-fwd-$k-mq" "ab-fwd-$k-web" ab-fwd-db | sort | paste -sd' ' -)" "forward sidecars"
  local l; l="$(run_line ab-fwd-db)"
  [[ "$l" == *"--network ab-egress --network ab-forward:alias=db "* ]] || fail "global networks: $l"
  [[ "$l" == *"--entrypoint=socat localhost/agentbox TCP-LISTEN:5432,fork,reuseaddr TCP:db.test.example:5432" ]] || fail "socat command: $l"
  [[ "$l" == *"--label agentbox.forward=global "* ]] || fail "global label: $l"
  l="$(run_line "ab-fwd-$k-mq")"
  [[ "$l" == *"--network ab-fwd-$k:alias=mq "* ]] || fail "repo network: $l"
  [[ "$l" == *"--label agentbox.forward=repo-$k "* ]] || fail "repo label: $l"
  grep -qx "podman network exists ab-fwd-$k" "$STUB_DIR/calls" || fail "repo network not checked"
  local args; args="$(session_args)"
  grep -qx 'ab-forward' <<<"$args" || fail "session not on ab-forward"
  grep -qx "ab-fwd-$k" <<<"$args" || fail "session not on the repo network"
  grep -qx 'NO_PROXY=ab-mcp-context7,db,mq,web,ab-llm-openai\|NO_PROXY=db,mq,web,ab-llm-openai' <<<"$args" \
    || fail "NO_PROXY: $(grep NO_PROXY <<<"$args")"
}

test_forward_recreated_and_removed() {
  setup "${FUNCNAME[0]}"
  config "AB_FORWARD=db=db.test.example:5432"
  mkdir -p "$CFG/env"
  echo "AB_FORWARD=mq=mq.test.example:5672" > "$CFG/env/repo.conf"
  ab_run --
  ab_run --
  run_line ab-fwd-db && fail "recreated without a change"
  # Another repo's sidecar: not this start's business.
  echo "ab-fwd-ffffffff-x localhost/agentbox" >> "$STUB_DIR/running"
  echo "ab-fwd-ffffffff-x agentbox.forward=repo-ffffffff" >> "$STUB_DIR/labels"
  : > "$CFG/config.env"; config "AB_FORWARD=db=db2.test.example:5432"
  ab_run --
  run_line ab-fwd-db | grep -q 'TCP:db2.test.example:5432' || fail "not recreated after the target changed"
  ab_run STUB_IMAGE_ID=img-2 --
  run_line ab-fwd-db >/dev/null || fail "not recreated on a new agentbox image"
  rm "$CFG/env/repo.conf"; : > "$CFG/config.env"
  ab_run --
  assert_rc 0
  assert_out "removed ab-fwd-db, no longer in AB_FORWARD"
  assert_out "removed ab-fwd-$(fwd_key)-mq, no longer in AB_FORWARD"
  assert_eq "$(started | tr ' ' '\n' | grep '^ab-fwd' | paste -sd' ' -)" "ab-fwd-ffffffff-x" "left"
  session_args | grep -q 'ab-forward\|ab-fwd-' && fail "session still on a forward network"
  grep -qx "podman network rm ab-fwd-$(fwd_key)" "$STUB_DIR/calls" || fail "repo network not removed"
}

test_forward_errors() {
  setup "${FUNCNAME[0]}"
  local e
  for e in 'db' 'Db=x.example:5432' 'ab-x=x.example:5432' 'db=x.example' 'db=.example:5432' 'db=x.example:70000' 'db=x;y:1' 'db=*:5432'; do
    : > "$CFG/config.env"; config "AB_FORWARD=$e"
    ab_run --
    assert_rc 2
  done
  : > "$CFG/config.env"; config "AB_FORWARD=db=x.example:5432"
  mkdir -p "$CFG/env"; echo "AB_FORWARD=db=y.example:5432" > "$CFG/env/repo.conf"
  ab_run --
  assert_rc 2
  assert_out "the name 'db' appears more than once"
  rm "$CFG/env/repo.conf"
  : > "$CFG/config.env"; config "AB_FORWARD=redis=x.example:6379" "AB_SERVICES=redis"
  ab_run --
  assert_rc 2
  assert_out "'redis' is also in AB_SERVICES"
  grep -q '^podman run -d' "$STUB_DIR/calls" && fail "sidecars started despite the error"
  : > "$CFG/config.env"; config "AB_FORWARD=db=x.example:5432"
  ab_run STUB_NO_SOCAT=1 --
  assert_rc 1
  assert_out "rebuild the image: AB_UPGRADE=1"
}

# --- review fixes (cr/2026-10-15) ---

test_worktree_git_file_read_only() {
  setup "${FUNCNAME[0]}"
  rm -rf "$REPO/.git"
  echo "gitdir: /somewhere/main/.git/worktrees/repo" > "$REPO/.git"
  ab_run --
  assert_rc 0
  assert_out "is a git worktree or submodule"
  session_args | grep -qx -- "$REPO/.git:/work/repo/.git:ro,z" || fail ".git file not read-only"
}

test_services_bypass_proxy() {
  setup "${FUNCNAME[0]}"
  config "AB_SERVICES=redis minio"
  ab_run --
  assert_rc 0
  session_args | grep -qx 'NO_PROXY=ab-mcp-context7,redis,minio,ab-llm-openai\|NO_PROXY=redis,minio,ab-llm-openai' \
    || fail "NO_PROXY: $(session_args | grep NO_PROXY)"
}

test_services_network_name_exact() {
  setup "${FUNCNAME[0]}"
  config "AB_SERVICES=redis"
  ab_run STUB_NETWORKS="podman ab-services-old" --
  assert_rc 0
  grep -qx 'podman network connect ab-services redis' "$STUB_DIR/calls" || fail "not attached: ab-services-old taken for ab-services"
  ab_run --
  grep -q '^podman network connect' "$STUB_DIR/calls" && fail "attached again although already on ab-services"
}

# Woodpecker: the token only in nginx, the server read-only and without a
# way out, nginx letting the server read only; the URL and CA checked.
test_mcp_woodpecker() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=woodpecker" "WOODPECKER_URL=https://ci.example/api/"
  secrets woodpecker_token
  ab_run --
  assert_rc 0
  assert_eq "$(started)" "ab-egress ab-mcp-woodpecker ab-mcp-woodpecker-srv" "sidecars"
  assert_out "created secret woodpecker_bridge_key"
  local srv nginx t="$ROOT/mcp/woodpecker/nginx.conf.template"
  srv="$(run_line ab-mcp-woodpecker-srv)"; nginx="$(run_line ab-mcp-woodpecker)"
  [[ "$srv" == *"--network ab-mcp-woodpecker --dns 127.0.0.1 "* ]] || fail "server network: $srv"
  [[ "$srv" != *ab-internal* && "$srv" != *ab-egress* ]] || fail "the server sees squid or the outside: $srv"
  [[ "$srv" == *"-e WOODPECKER_MCP_READ_ONLY=true "* ]] || fail "server not read-only: $srv"
  [[ "$srv" == *"-e WOODPECKER_SERVER=http://ab-mcp-woodpecker:8081 "* ]] || fail "server not behind nginx: $srv"
  [[ "$srv" != *woodpecker_token* ]] || fail "the server has the Woodpecker token"
  [[ "$srv" == *" ghcr.io/rtuszik/woodpecker-mcp:"[0-9]* ]] || fail "server image not pinned: $srv"
  [[ "$nginx" == *"--network ab-internal --network ab-egress --network ab-mcp-woodpecker "* ]] || fail "nginx networks: $nginx"
  assert_file_has "$ROOT/mcp/woodpecker/mcp.sh" 'podman network create --internal ab-mcp-woodpecker'
  [[ "$nginx" == *"-e WOODPECKER_URL=https://ci.example "* ]] || fail "URL not normalised: $nginx"
  [[ "$nginx" == *"-e WOODPECKER_CA_FILE=/etc/ssl/certs/ca-certificates.crt "* ]] || fail "default CA: $nginx"
  [[ "$nginx" == *"woodpecker_token,type=env,target=WP_TOKEN"* ]] || fail "nginx lacks the token"
  session_args | grep -qx 'woodpecker_mcp_caller,type=env,target=AB_MCP_TOKEN_WOODPECKER' || fail "caller token not passed"
  # A renewed token (agentbox setup): nginx, which holds it, is recreated.
  ab_run --
  run_line ab-mcp-woodpecker && fail "recreated without a change"
  echo new-token > "$STUB_DIR/secret-woodpecker_token"
  ab_run --
  run_line ab-mcp-woodpecker >/dev/null || fail "nginx kept the old token"
  run_line ab-mcp-woodpecker-srv && fail "the server recreated for the token"
  # Both forms of --secret count.
  local ids
  ids="$(PATH="$T/bin:$PATH" bash -c 'source "$1/lib/sidecars.sh"; secret_ids_load; secret_ids --secret woodpecker_token,type=env --secret=woodpecker_bridge_key,type=env' _ "$ROOT")"
  assert_eq "$(cut -d' ' -f2 <<<"$ids" | paste -sd' ')" "woodpecker_token woodpecker_bridge_key" "secret_ids"
  assert_eq "$(cut -d' ' -f3 <<<"$ids" | grep -c '^id-[0-9]')" 2 "secret IDs"
  # The daily scan covers the pinned image.
  local image; image="$(sed -n 's/^WOODPECKER_MCP_IMAGE="\(.*\)"$/\1/p' "$ROOT/mcp/woodpecker/mcp.sh")"
  grep -qF -- "$image" "$ROOT/.github/workflows/scan.yml" || fail "scan.yml does not scan $image"
  # The template: bridge key towards the server, GET and HEAD only and the token
  # towards Woodpecker, its certificate verified.
  assert_file_has "$t" 'proxy_set_header Authorization "Bearer \$\{WP_BRIDGE_KEY\}";'
  assert_file_has "$t" 'if \(\$http_authorization != "Bearer \$\{WP_BRIDGE_KEY\}"\)'
  assert_file_has "$t" 'limit_except GET \{'
  assert_file_has "$t" 'proxy_set_header Authorization "Bearer \$\{WP_TOKEN\}";'
  assert_file_has "$t" 'proxy_ssl_verify on;'
  # A CA of your own is mounted; a missing one or a bad URL stops the start.
  echo "-----BEGIN CERTIFICATE-----" > "$T/ca.pem"
  : > "$CFG/config.env"; config "AB_MCP=woodpecker" "WOODPECKER_URL=https://ci.example" "WOODPECKER_CA=$T/ca.pem"
  ab_run --
  assert_rc 0
  run_line ab-mcp-woodpecker | grep -q -- "-e WOODPECKER_CA_FILE=/etc/nginx/woodpecker-ca.pem .*:/etc/nginx/woodpecker-ca.pem:ro,Z" \
    || fail "own CA not mounted: $(run_line ab-mcp-woodpecker)"
  : > "$CFG/config.env"; config "AB_MCP=woodpecker" "WOODPECKER_URL=https://ci.example" "WOODPECKER_CA=$T/missing.pem"
  ab_run --
  assert_skipped woodpecker
  assert_out "missing.pem is missing"
  local bad
  for bad in ci.example 'https://ci.example/;}server{' 'https://ci.example/$host' 'https://ci.example/#x' 'https://u:p@ci.example'; do
    : > "$CFG/config.env"; config "AB_MCP=woodpecker" "WOODPECKER_URL=$bad"
    ab_run --
    assert_skipped woodpecker
    assert_out "WOODPECKER_URL must be an http:// or https:// URL"
  done
  : > "$CFG/config.env"; config "AB_MCP=woodpecker" "WOODPECKER_URL=http://ci.example"
  ab_run --
  assert_rc 0
  assert_out "WOODPECKER_URL is http://: the Woodpecker token"
  : > "$CFG/config.env"; config "AB_MCP=woodpecker" "WOODPECKER_URL=https://ci.example//api//"
  ab_run --
  run_line ab-mcp-woodpecker | grep -q -- "-e WOODPECKER_URL=https://ci.example " || fail "slashes kept: $(run_line ab-mcp-woodpecker)"
  # A network of that name without --internal is not used.
  ab_run STUB_NET_INTERNAL=false --
  assert_skipped woodpecker
  assert_out "ab-mcp-woodpecker is not --internal"
  run_line ab-mcp-woodpecker-srv && fail "server started on a network with a way out"
  return 0
}

test_mcp_dbhub() {
  # config.py parses with tomllib (Python 3.11+), here as in the image.
  python3 -c 'import tomllib' 2>/dev/null || { echo "  (skipped: needs Python 3.11+ for tomllib)"; return 0; }
  setup "${FUNCNAME[0]}"
  config "AB_MCP=dbhub"
  # No dbhub.toml: the session starts without dbhub and says where it goes.
  ab_run --
  assert_skipped dbhub
  assert_out "the dbhub module needs .*/dbhub.toml"
  cat > "$CFG/dbhub.toml" <<'TOML'
# two databases
[[sources]]
id = "billing"
dsn = "postgres://ro:p#ss@db1.lan:5432/billing?sslmode=require"

[[sources]]
id = 'crm'   # single quotes
description = "CRM"
dsn = "postgres://ro:x@db2.lan:5432/crm"
TOML
  chmod 644 "$CFG/dbhub.toml"
  ab_run --
  assert_rc 0
  assert_out "dbhub.toml holds database passwords and the group or others may read it"
  assert_eq "$(started)" "ab-egress ab-mcp-dbhub" "sidecars"
  local l f
  l="$(run_line ab-mcp-dbhub)"
  [[ "$l" == *"--network ab-internal --network ab-egress "* ]] || fail "networks: $l"
  [[ "$l" == *"dbhub_mcp_caller,type=env,target=DBHUB_AUTH_TOKEN"* ]] || fail "no caller auth: $l"
  [[ "$l" == *"-e DBHUB_ALLOWED_HOSTS=ab-mcp-dbhub "* ]] || fail "no Host allowlist: $l"
  [[ "$l" == *" docker.io/bytebase/dbhub:"[0-9]*" --transport http --port 8080 --config /etc/dbhub/dbhub.toml" ]] || fail "image or arguments: $l"
  session_args | grep -qx 'dbhub_mcp_caller,type=env,target=AB_MCP_TOKEN_DBHUB' || fail "caller token not passed"
  # The mounted config: written anew from the parse, read-only tools for
  # each source; private.
  f="$(sed -n 's/.* -v \([^ ]*\):\/etc\/dbhub\/dbhub.toml:ro,Z .*/\1/p' <<<"$l")"
  [[ -f "$f" ]] || fail "mounted config missing: $f"
  assert_eq "$(stat -c %a "$f")" 600 "config mode"
  assert_file_has "$f" '^dsn = "postgres://ro:p#ss@db1'
  assert_file_has "$f" '^id = "crm"$'
  grep -q 'two databases\|single quotes' "$f" && fail "text of dbhub.toml reached DBHub"
  assert_eq "$(grep -c '^readonly = true$' "$f")" 2 "read-only execute_sql per source"
  assert_eq "$(grep -A1 '^name = "execute_sql"$' "$f" | grep -o '"[a-z]*"$' | paste -sd' ')" '"billing" "crm"' "sources"
  assert_eq "$(grep -c '^name = "search_objects"$' "$f")" 2 "search_objects per source"
  # A changed source recreates the sidecar; an unchanged one, or a comment,
  # does not.
  chmod 600 "$CFG/dbhub.toml"
  ab_run --
  grep -q -- '--entrypoint python3' "$STUB_DIR/calls" && fail "parsed again without a change"
  echo '# a comment' >> "$CFG/dbhub.toml"
  ab_run --
  run_line ab-mcp-dbhub && fail "recreated without a change"
  grep -q "others may read it" "$T/out" && fail "warned about a private file"
  echo 'query_timeout = 30' >> "$CFG/dbhub.toml"
  ab_run --
  run_line ab-mcp-dbhub >/dev/null || fail "not recreated for a changed dbhub.toml"
  # What DBHub gets comes from the parse: an id hidden in a multi-line string
  # (review 3) is just text in a value.
  printf '[[sources]]\nid = """prod"""\ndsn = "x"\nx = %s # %s\nid = "decoy"\ny = %s#%s\n' "'''" "'" "'''" "'" > "$CFG/dbhub.toml"
  ab_run --
  assert_rc 0
  assert_eq "$(grep -A1 '^name = "execute_sql"$' "$f" | grep -o '"[a-z]*"$' | paste -sd' ')" '"prod"' "source from the parse"
  assert_eq "$(grep -c '^\[\[sources\]\]$' "$f")" 1 "one source"
  # Nothing but [[sources]]: a tool of yours could write. Each refusal stops
  # the sidecar of the last start and removes its copy.
  local bad
  for bad in '[[tools]]' "[['tools']]" '[other]' "'tools' = 1"; do
    printf '[[sources]]\nid = "a"\ndsn = "postgres://x@h/d"\n%s\nname = "purge"\n' "$bad" > "$CFG/dbhub.toml"
    [[ "$bad" == "'tools' = 1" ]] && printf "'tools' = 1\n[[sources]]\nid = \"a\"\n" > "$CFG/dbhub.toml"
    ab_run --
    assert_skipped dbhub
    assert_out "dbhub.toml: (only \[\[sources\]\] entries may be there|not valid TOML)"
    if [[ "$bad" == '[[tools]]' ]]; then
      grep -qx 'podman rm -f -v ab-mcp-dbhub' "$STUB_DIR/calls" || fail "old sidecar left serving"
      [[ -e "$(dirname "$f")" ]] && fail "old copy with the passwords left"
    fi
  done
  # The copy goes also when its container is gone already.
  printf '[[sources]]\nid = "a"\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_rc 0
  sed -i '/^ab-mcp-dbhub /d' "$STUB_DIR/running"
  rm -f "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  [[ -e "$(dirname "$f")" ]] && fail "copy with the passwords left without its container"
  for bad in 'x = 1' 'x = { a = 1 }' 'x = [[1]]' 'x = 1979-05-27' '"a b" = 1'; do
    printf '[[sources]]\nid = "a"\n%s\n' "$bad" > "$CFG/dbhub.toml"
    ab_run --
    if [[ "$bad" == 'x = 1' ]]; then assert_rc 0; continue; fi
    assert_skipped dbhub
    assert_out "dbhub.toml: source 'a'"
  done
  printf '[[sources]]\nid = "a"\ndescription = "${DBHUB_AUTH_TOKEN}"\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  assert_out "source 'a', description: '\\$\{' is not supported"
  printf '[[sources]]\nid = "a"\nd = "open\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  assert_out "dbhub.toml: not valid TOML"
  # The reason is in the warning, not "see the output above".
  assert_out "dbhub' left out of this session: .*dbhub.toml: not valid TOML"
  # DBHub reads - as _ in tool names.
  printf '[[sources]]\nid = "prod-db"\n[[sources]]\nid = "prod_db"\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  assert_out "source id 'prod_db' is the same as another"
  printf '[[sources]]\nid = "a"\n[[sources]]\ndsn = "postgres://x@h/d"\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  assert_out "\[\[sources\]\] entry 2 needs an id"
  printf '[[sources]]\nid = "a b"\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  assert_out "entry 1 needs an id of letters"
  printf '# nothing yet\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_skipped dbhub
  assert_out "dbhub.toml: no \[\[sources\]\] entry"
  # The daily scan covers the pinned image.
  local image; image="$(sed -n 's/^DBHUB_IMAGE="\(.*\)"$/\1/p' "$ROOT/mcp/dbhub/mcp.sh")"
  grep -qF -- "$image" "$ROOT/.github/workflows/scan.yml" || fail "scan.yml does not scan $image"
  # Turned off: the sidecar and the copy with the passwords go.
  printf '[[sources]]\nid = "a"\n' > "$CFG/dbhub.toml"
  ab_run --
  assert_rc 0
  [[ -f "$f" ]] || fail "no copy to remove"
  printf 'ab-mcp-dbhub x\n' >> "$STUB_DIR/running"
  : > "$CFG/config.env"
  ab_run --
  assert_rc 0
  [[ -e "$(dirname "$f")" ]] && fail "the copy with the passwords stayed"
  return 0
}

test_secret_list_failure_stops_the_start() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana" "GRAFANA_URL=https://g.example"
  secrets grafana_sa
  ab_run STUB_SECRET_LS_FAIL=1 --
  assert_rc 1
  assert_out "cannot list the Podman secrets"
  grep -q '^podman secret create\|^podman run -d' "$STUB_DIR/calls" && fail "went on as if there were no secrets"
  return 0
}

test_secret_store_reports_a_failed_create() {
  setup "${FUNCNAME[0]}"
  local rc old
  # An existing secret, so that new podman takes the --replace branch. In an
  # if, as agentbox setup calls it: set -e does not stop it there.
  secrets mytoken
  for old in "" 1; do
    PATH="$T/bin:$PATH" STUB_SECRET_CREATE_FAIL=1 STUB_OLD_PODMAN="$old" bash -c \
      'set -euo pipefail; source "$1/lib/sidecars.sh"; if printf tok | secret_store mytoken; then exit 0; else exit 7; fi' _ "$ROOT" 2>/dev/null
    rc=$?
    assert_eq "$rc" 7 "secret_store status, old podman '$old'"
  done
  return 0
}

test_github_nginx_follows_its_server() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=github"
  secrets github_pat
  ab_run --
  ab_run --
  run_line ab-mcp-github && fail "nginx recreated without a change"
  # check-updates.sh removes the server for a new image; nginx must follow.
  grep -v '^ab-mcp-github-srv ' "$STUB_DIR/running" > "$STUB_DIR/r"; mv "$STUB_DIR/r" "$STUB_DIR/running"
  ab_run --
  run_line ab-mcp-github-srv >/dev/null || fail "server not recreated"
  run_line ab-mcp-github >/dev/null || fail "nginx kept the old server's address"
}

test_github_more_owners() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=github" "GH_OWNERS=MyOrg, other-org myorg"
  secrets github_pat github_pat_myorg
  # A token for each owner: without one, the module is left out.
  ab_run --
  assert_skipped github
  assert_out "missing podman secrets github_pat_other-org"
  secrets github_pat github_pat_myorg github_pat_other-org
  ab_run --
  assert_rc 0
  # A server for each owner (lowercase, once), at its own path of nginx.
  local j; j="$(cache mcp-claude.json)"
  grep -q '"github": { "type": "http", "url": "http://ab-mcp-github:8080/mcp"' "$j" || fail "main server missing"
  grep -q '"github-myorg": { "type": "http", "url": "http://ab-mcp-github:8080/o/myorg/mcp"' "$j" || fail "github-myorg missing"
  grep -q '"github-other-org": .*/o/other-org/mcp"' "$j" || fail "github-other-org missing"
  assert_eq "$(grep -c '"github' "$j")" 3 "servers"
  # nginx gets each PAT under a numbered name, and a location for each.
  run_line ab-mcp-github | grep -q -- '--secret github_pat_myorg,type=env,target=GH_PAT_1 ' || fail "PAT of myorg not GH_PAT_1"
  run_line ab-mcp-github | grep -q -- '--secret github_pat_other-org,type=env,target=GH_PAT_2 ' || fail "PAT of other-org not GH_PAT_2"
  local t; t="$(cache sidecars/ab-mcp-github/default.conf.template)"
  assert_file_has "$t" 'location = /mcp \{'
  assert_file_has "$t" 'location = /o/myorg/mcp \{'
  assert_file_has "$t" 'location = /o/other-org/mcp \{'
  assert_eq "$(grep -c 'Bearer \${GH_PAT_1}' "$t")" 1 "GH_PAT_1 uses"
  assert_eq "$(grep -c 'Bearer \${GH_PAT}"' "$t")" 1 "GH_PAT uses"
  assert_eq "$(grep -c 'location / { return 404; }' "$t")" 1 "catch-all"
  # A name that is not a GitHub name: left out, with the reason.
  sed -i 's/^GH_OWNERS=.*/GH_OWNERS=bad_name/' "$CFG/config.env"
  ab_run --
  assert_skipped github
  assert_out "GH_OWNERS must hold GitHub user or organization names, got: bad_name"
}

# tab_setup <test name>: the tabularis module enabled, with stand-ins for
# node, npm, Tabularis and ss on the host. The stub systemd has no cgroups, so ss
# never shows the bridge as the one listening: the module would take any
# listener for another program. TAB_PORT and TAB_PORT2 are ports nothing
# listens on, not the default one, where a real bridge may run.
tab_setup() {
  setup "$1"
  TAB_PORT="$(free_port 47900)"
  TAB_PORT2="$(free_port $((TAB_PORT + 1)))"
  config "AB_MCP=tabularis" "TABULARIS_PORT=$TAB_PORT"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/node"
  # npm ci: records the call and installs a stand-in supergateway, or fails
  # with STUB_NPM_FAIL.
  cat > "$T/bin/npm" <<'NPM'
#!/bin/sh
echo "npm $* (in $PWD)" >> "$STUB_DIR/npm-calls"
[ "$1" = ci ] || exit 0
[ -z "${STUB_NPM_FAIL:-}" ] || exit 1
mkdir -p node_modules/.bin && printf '#!/bin/sh\n' > node_modules/.bin/supergateway && chmod +x node_modules/.bin/supergateway
NPM
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/tabularis"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/ss"
  chmod +x "$T/bin/node" "$T/bin/npm" "$T/bin/tabularis" "$T/bin/ss"
}
bridge_line() { grep '^systemd-run ' "$STUB_DIR/calls"; }
tab_port() {  # <port>: TABULARIS_PORT in config.env, replacing the one there
  sed -i '/^TABULARIS_PORT=/d' "$CFG/config.env"
  config "TABULARIS_PORT=$1"
}
free_port() {  # <first>: the first port from <first> on that nobody listens on
  local p="$1"
  while (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; do p=$((p + 1)); done
  echo "$p"
}

test_tabularis_wiring() {
  tab_setup "${FUNCNAME[0]}"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 0
  assert_eq "$(started)" "ab-egress ab-mcp-tabularis ab-mcp-tabularis-relay" "sidecars"
  assert_out "created the tabularis bridge key"
  assert_out "the tabularis bridge does not answer on 127.0.0.1:$TAB_PORT"
  local key; key="$(cache tabularis/bridge.key)"
  [[ -s "$key" ]] || fail "no bridge key file"
  assert_eq "$(stat -c %a "$key")" 600 "key file mode"
  assert_eq "$(cat "$STUB_DIR/secret-tabularis_bridge_key")" "$(cat "$key")" "secret and key file"
  # The bridge: supergateway, pinned, one Tabularis per session, loopback
  # only, with the key, Tabularis's stderr dropped.
  local b; b="$(bridge_line)"
  [[ "$b" == *" --unit=agentbox-mcp-tabularis "* ]] || fail "unit name: $b"
  local bridge; bridge="$(cache tabularis)/bridge-$(bridge_hash)"
  [[ "$b" == *" -- $bridge/node_modules/.bin/supergateway "* ]] || fail "supergateway not from the lock file's install: $b"
  [[ "$b" != *npx* ]] || fail "npx used: $b"
  grep -q "^npm ci --ignore-scripts --omit=dev .*(in $(cache tabularis)/\.install\." "$STUB_DIR/npm-calls" \
    || fail "not installed with npm ci --ignore-scripts: $(cat "$STUB_DIR/npm-calls" 2>/dev/null)"
  [[ "$b" == *" --stdio tabularis --mcp 2>/dev/null "* ]] || fail "stdio command: $b"
  [[ "$b" == *" --stateful --host 127.0.0.1 --port $TAB_PORT --apiKeyFile $key --logLevel none" ]] || fail "options: $b"
  [[ "$b" == *" --setenv=PATH=$T/bin:$T/bin:"* ]] || fail "PATH: $b"
  [[ "$b" == *" --property=StartLimitIntervalSec=60 --property=StartLimitBurst=3 "* ]] || fail "no start limit: $b"
  # The relay on the host network, nginx on ab-internal only.
  run_line ab-mcp-tabularis-relay | grep -q -- "--network host .*TCP:127.0.0.1:$TAB_PORT\$" || fail "relay: $(run_line ab-mcp-tabularis-relay)"
  local n; n="$(run_line ab-mcp-tabularis)"
  [[ "$n" == *"--network ab-internal "* && "$n" != *ab-egress* ]] || fail "nginx networks: $n"
  [[ "$n" == *"tabularis_bridge_key,type=env,target=TABULARIS_BRIDGE_KEY"* ]] || fail "nginx lacks the key"
  session_args | grep -qx 'tabularis_mcp_caller,type=env,target=AB_MCP_TOKEN_TABULARIS' || fail "caller token not passed"
  assert_file_has "$(cache mcp-claude.json)" '"tabularis": \{ "type": "http", "url": "http://ab-mcp-tabularis:8080/mcp"'
  # Nothing changed: nothing restarted, nothing installed again.
  : > "$STUB_DIR/npm-calls"
  ab_run AB_TABULARIS_WAIT=0 --
  bridge_line >/dev/null && fail "bridge restarted without a change"
  [[ -s "$STUB_DIR/npm-calls" ]] && fail "installed again without a change"
  run_line ab-mcp-tabularis && fail "nginx recreated without a change"
  assert_no_out "created the tabularis bridge key"
  return 0
}

# A new lock file (or new overrides): a new install, the bridge restarted
# on it. Installs unused for 30 days go; recent ones stay, another agentbox
# copy may use them. A failed install stops the start. Leftovers of
# interrupted installs go, a half install is replaced.
test_tabularis_bridge_install() {
  tab_setup "${FUNCNAME[0]}"
  local base; base="$(cache tabularis)"
  ab_run AB_TABULARIS_WAIT=0 --
  local old; old="$(ls -d "$base"/bridge-*)"
  sed -i 's/"private": true/"private": true /' "$AB/mcp/tabularis/bridge/package.json"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 0
  local new; new="$base/bridge-$(bridge_hash)"
  bridge_line | grep -qF -- "$new/node_modules" || fail "bridge not restarted on the new install: $(bridge_line)"
  [[ -e "$old" ]] || fail "a recent install removed"
  touch -d '40 days ago' "$old" "$new"
  ab_run AB_TABULARIS_WAIT=0 --
  [[ -e "$old" ]] && fail "an install unused for 40 days kept"
  [[ -e "$new" ]] || fail "the install in use removed"
  # npm ci fails: the session starts without tabularis and says why.
  echo " " >> "$AB/mcp/tabularis/bridge/package-lock.json"
  ab_run AB_TABULARIS_WAIT=0 STUB_NPM_FAIL=1 --
  assert_skipped tabularis
  assert_out "could not install the tabularis bridge: npm ci failed"
  ls -d "$base"/.install.* 2>/dev/null && fail "failed install left"
  # A leftover older than an hour goes; a half install is replaced.
  mkdir -p "$base/.install.old"; touch -d '2 hours ago' "$base/.install.old"
  local half; half="$base/bridge-$(bridge_hash)"
  mkdir -p "$half/node_modules/express"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 0
  [[ -e "$base/.install.old" ]] && fail "old leftover kept"
  [[ -x "$half/node_modules/.bin/supergateway" ]] || fail "half install not replaced"
  [[ -e "$half/node_modules/express" ]] && fail "half install's files kept"
  return 0
}

test_tabularis_bridge_files_missing() {
  tab_setup "${FUNCNAME[0]}"
  rm "$AB/mcp/tabularis/bridge/package-lock.json"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_skipped tabularis
  assert_out "lacks bridge/package.json or bridge/package-lock.json"
}

test_tabularis_changes_restart() {
  tab_setup "${FUNCNAME[0]}"
  ab_run AB_TABULARIS_WAIT=0 --
  # Another port: the bridge and the relay follow, nginx stays.
  tab_port "$TAB_PORT2"
  ab_run AB_TABULARIS_WAIT=0 --
  bridge_line | grep -q -- "--port $TAB_PORT2 " || fail "bridge not restarted for the port"
  run_line ab-mcp-tabularis-relay | grep -q "TCP:127.0.0.1:$TAB_PORT2\$" || fail "relay not recreated"
  run_line ab-mcp-tabularis && fail "nginx recreated for the port"
  # The key file gone (cache cleaned): a new key for both sides.
  local old; old="$(cat "$STUB_DIR/secret-tabularis_bridge_key")"
  rm "$(cache tabularis/bridge.key)"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_out "created the tabularis bridge key"
  [[ "$(cat "$STUB_DIR/secret-tabularis_bridge_key")" != "$old" ]] || fail "secret not replaced"
  bridge_line >/dev/null || fail "bridge not restarted for the new key"
  run_line ab-mcp-tabularis >/dev/null || fail "nginx not recreated for the new key"
  # AB_RESTART restarts the bridge too.
  ab_run AB_TABULARIS_WAIT=0 AB_RESTART=1 --
  bridge_line >/dev/null || fail "bridge not restarted with AB_RESTART"
}

test_tabularis_disabled_stops_bridge() {
  tab_setup "${FUNCNAME[0]}"
  ab_run AB_TABULARIS_WAIT=0 --
  echo "agentbox-mine.service my own service" >> "$STUB_DIR/units"
  : > "$CFG/config.env"
  ab_run --
  assert_rc 0
  assert_out "stopped agentbox-mcp-tabularis.service, no longer enabled"
  assert_eq "$(awk '{ print $1 }' "$STUB_DIR/units")" "agentbox-mine.service" "units left"
  assert_eq "$(started)" "ab-egress" "sidecars"
}

# A parallel start that took the unit name first is fine; a real failure
# stops the start. A host service that will not stop does not.
test_tabularis_host_unit_failures() {
  tab_setup "${FUNCNAME[0]}"
  ab_run AB_TABULARIS_WAIT=0 STUB_RUN_RACE=1 --
  assert_rc 0
  : > "$STUB_DIR/units"
  ab_run AB_TABULARIS_WAIT=0 STUB_RUN_FAIL=1 --
  assert_skipped tabularis
  assert_out "could not start the host service agentbox-mcp-tabularis"
  ab_run AB_TABULARIS_WAIT=0 --
  : > "$CFG/config.env"
  ab_run STUB_STOP_FAIL=1 --
  assert_rc 0
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "session did not start"
}

# A bridge that died is not waited for.
test_tabularis_dead_bridge_not_waited_for() {
  tab_setup "${FUNCNAME[0]}"
  local t0=$SECONDS
  ab_run AB_TABULARIS_WAIT=30 STUB_RUN_DIES=1 --
  assert_rc 0
  (( SECONDS - t0 < 10 )) || fail "waited $((SECONDS - t0)) s for a dead bridge"
  assert_out "the tabularis bridge does not answer"
}

# A key file that is there but empty, with a mode others can read: made anew
# with mode 600.
test_tabularis_key_file_mode() {
  tab_setup "${FUNCNAME[0]}"
  mkdir -p "$(cache tabularis)"
  : > "$(cache tabularis/bridge.key)"
  chmod 644 "$(cache tabularis/bridge.key)"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 0
  [[ -s "$(cache tabularis/bridge.key)" ]] || fail "key not written"
  assert_eq "$(stat -c %a "$(cache tabularis/bridge.key)")" 600 "key file mode"
  # The secret is written only when needed: not on every start, again when
  # it is missing, and from the file with AB_RESTART=1.
  ab_run AB_TABULARIS_WAIT=0 --
  grep -q '^podman secret create .*tabularis_bridge_key' "$STUB_DIR/calls" && fail "secret rewritten without a reason"
  grep -vx tabularis_bridge_key "$STUB_DIR/secrets" > "$STUB_DIR/s"; mv "$STUB_DIR/s" "$STUB_DIR/secrets"
  ab_run AB_TABULARIS_WAIT=0 --
  grep -qx tabularis_bridge_key "$STUB_DIR/secrets" || fail "missing secret not written again"
  echo other > "$STUB_DIR/secret-tabularis_bridge_key"
  ab_run AB_TABULARIS_WAIT=0 AB_RESTART=1 --
  assert_eq "$(cat "$STUB_DIR/secret-tabularis_bridge_key")" "$(cat "$(cache tabularis/bridge.key)")" "secret after AB_RESTART=1"
}

# Another program on the port: no bridge, no sidecars, an error.
test_tabularis_port_taken() {
  command -v python3 >/dev/null || return 0
  tab_setup "${FUNCNAME[0]}"
  python3 -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
print(s.getsockname()[1], flush=True); time.sleep(30)' > "$T/port" &
  local pid=$! i
  for (( i = 0; i < 50; i++ )); do [[ -s "$T/port" ]] && break; sleep 0.1; done
  tab_port "$(cat "$T/port")"
  # Running from an earlier start, for open sessions.
  printf '%s\n' "ab-mcp-tabularis x" "ab-mcp-tabularis-relay y" >> "$STUB_DIR/running"
  ab_run AB_TABULARIS_WAIT=0 --
  kill "$pid" 2>/dev/null
  assert_skipped tabularis
  assert_out "TABULARIS_PORT $(cat "$T/port") on 127.0.0.1 is in use by another program"
  grep -q '^systemd-run' "$STUB_DIR/calls" && fail "bridge started on a taken port"
  grep -qx 'podman rm -f -v ab-mcp-tabularis-relay' "$STUB_DIR/calls" || fail "relay left sending to the other program"
  assert_eq "$(started)" "ab-egress" "sidecars"
}

test_tabularis_errors() {
  tab_setup "${FUNCNAME[0]}"
  config 'TABULARIS_CMD=tabularis $(touch x)'
  ab_run AB_TABULARIS_WAIT=0 --
  assert_skipped tabularis
  assert_out "TABULARIS_CMD may hold only"
  local p
  for p in 80 08080 70000; do
    : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_PORT=$p"
    ab_run AB_TABULARIS_WAIT=0 --
    assert_skipped tabularis
    assert_out "TABULARIS_PORT must be a port from 1024 to 65535, got '$p'"
  done
  : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_CMD=./bin/tabularis"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_skipped tabularis
  assert_out "give the command by name or as an absolute path, got './bin/tabularis'"
  : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_CMD= tabularis"
  ab_run AB_TABULARIS_WAIT=0 TABULARIS_CMD=" tabularis" --
  assert_skipped tabularis
  assert_out "starts with the command"
  : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_CMD=no-such-tabularis"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_skipped tabularis
  assert_out "'no-such-tabularis' not found"
  grep -q '^systemd-run' "$STUB_DIR/calls" && fail "bridge started despite the error"
  return 0
}

test_skill_sources_same_repository() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d a "url = '$SRC'" "only = ['tdd']"
  src_conf skills.d b "url = '$SRC'" "only = ['review']"
  config "AB_SKILLS=a b"
  ab_run --
  assert_rc 2
  assert_out "sources 'a' and 'b' both use"
}

test_sync_refuses_symlinks() {
  ss_setup "${FUNCNAME[0]}"
  echo "HOST-SECRET" > "$T/secret.txt"
  ln -s ../../../../secret.txt "$SRC/eng/tdd/notes.md"
  git -C "$SRC" add -A
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m link
  ss_run
  assert_rc 1
  assert_out "skill 'tdd' in .* contains symlinks"
  grep -rqs HOST-SECRET "$CFG/skills" && fail "a host file reached the skills"
  [[ -e "$CFG/skills/acme-tdd" ]] && fail "skill installed anyway"
}

test_updates_image_references() {
  cu_setup "${FUNCNAME[0]}"
  printf '%s\n' "ab-mcp-a ghcr.io/org/mcp" "ab-mcp-b localhost:5000/team/mcp:v2" \
    "ab-mcp-c nginx" "ab-mcp-d ghcr.io/org/pinned@sha256:abc" > "$STUB_DIR/running"
  cu_run
  grep -qx 'https://ghcr.io/v2/org/mcp/manifests/latest' "$T/urls" || fail "untagged: $(cat "$T/urls")"
  grep -qx 'https://localhost:5000/v2/team/mcp/manifests/v2' "$T/urls" || fail "registry port: $(cat "$T/urls")"
  grep -qx 'https://registry-1.docker.io/v2/library/nginx/manifests/latest' "$T/urls" || fail "short name: $(cat "$T/urls")"
  grep -q pinned "$T/urls" && fail "a digest reference was checked"
  assert_no_out "could not check ghcr.io/org/pinned"
}

# --- git-guard: real git, real attacks ---------------------------------------

# A repository at $R, recorded as mounted; $T/gbin/git is the wrapper.
# MARK is the file an attack's command would create.
gg_setup() {
  setup "$1"
  mkdir -p "$T/gbin"
  cp "$ROOT/git-guard" "$T/gbin/git"
  chmod +x "$T/gbin/git"
  R="$T/proj"
  git init -q -b main "$R"
  git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  echo "$R" > "$CFG/mounted-repos"
  MARK="$T/pwned"
}
# gg <dir> <git args...>: the wrapper, from <dir>.
gg() {
  local d="$1"; shift
  (cd "$d" && env HOME="$T/home" PATH="$T/gbin:$PATH" git "$@") > "$T/out" 2>&1
  RC=$?
}
# bare_git <dir> <git args...>: the real git, as without the wrapper.
bare_git() {
  local d="$1"; shift
  (cd "$d" && env HOME="$T/home" git "$@") > "$T/out.bare" 2>&1
}
# A directory with the agent's config: core.fsmonitor creates MARK.
evil_common_dir() {  # <dir>
  mkdir -p "$1"
  cp -R "$R/.git/objects" "$R/.git/refs" "$R/.git/HEAD" "$1/"
  printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = "touch %s; false"\n' "$MARK" > "$1/config"
}

test_guard_clean_and_unlisted_repos_pass() {
  gg_setup "${FUNCNAME[0]}"
  gg "$R" status --short
  assert_rc 0
  git init -q "$T/other"
  gg "$T/other" status --short
  assert_rc 0
  gg "$T" --version
  assert_rc 0
}

# Two copies in PATH (one installed, one in a test or an older place): each
# skips the other instead of calling it forever.
test_guard_two_copies_in_path() {
  gg_setup "${FUNCNAME[0]}"
  mkdir -p "$T/gbin2"
  cp "$ROOT/git-guard" "$T/gbin2/git"
  chmod +x "$T/gbin2/git"
  (cd "$R" && env HOME="$T/home" PATH="$T/gbin:$T/gbin2:$PATH" timeout 20 git status --short) > "$T/out" 2>&1
  RC=$?
  assert_rc 0
  evil_common_dir "$R/evil"
  echo ../evil > "$R/.git/commondir"
  (cd "$R" && env HOME="$T/home" PATH="$T/gbin:$T/gbin2:$PATH" timeout 20 git status --short) > "$T/out" 2>&1
  RC=$?
  assert_rc 1
  assert_out "commondir exists"
  assert_out "this check is the wrapper $T/gbin/git"
}

test_guard_stops_commondir() {
  gg_setup "${FUNCNAME[0]}"
  evil_common_dir "$R/evil"
  echo ../evil > "$R/.git/commondir"
  bare_git "$R" status --short
  [[ -e "$MARK" ]] || fail "control: the attack did not work on plain git"
  rm -f "$MARK"
  gg "$R" status --short
  assert_rc 1
  assert_out "commondir exists"
  [[ -e "$MARK" ]] && fail "the agent's command ran"
  # The same through -C, from outside the repository.
  gg "$T" -C proj status --short
  assert_rc 1
  [[ -e "$MARK" ]] && fail "the agent's command ran (-C)"
}

test_guard_worktrees() {
  gg_setup "${FUNCNAME[0]}"
  git -C "$R" worktree add -q "$R/.claude/worktrees/a" 2>/dev/null
  gg "$R/.claude/worktrees/a" status --short
  assert_rc 0
  # The agent builds a fake repository inside the tree and points the
  # worktree's .git file at it.
  git init -q -b main "$R/fake"
  git -C "$R/fake" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
  git -C "$R/fake" worktree add -q "$T/fake-wt" 2>/dev/null
  printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = "touch %s; false"\n' "$MARK" >> "$R/fake/.git/config"
  cp "$T/fake-wt/.git" "$R/.claude/worktrees/a/.git"
  bare_git "$R/.claude/worktrees/a" status --short
  [[ -e "$MARK" ]] || fail "control: the attack did not work on plain git"
  rm -f "$MARK"
  gg "$R/.claude/worktrees/a" status --short
  assert_rc 1
  assert_out "instead of $R/.git"
  [[ -e "$MARK" ]] && fail "the agent's command ran"
}

test_guard_rebase_exec_lines() {
  gg_setup "${FUNCNAME[0]}"
  mkdir -p "$R/.git/rebase-merge"
  printf 'pick 0000000 x\nexec touch %s\n' "$MARK" > "$R/.git/rebase-merge/git-rebase-todo"
  gg "$R" rebase --continue
  assert_rc 1
  assert_out "exec lines"
  [[ -e "$MARK" ]] && fail "the exec line ran"
}

test_guard_submodule_passes() {
  gg_setup "${FUNCNAME[0]}"
  git init -q -b main "$T/lib"
  git -C "$T/lib" -c user.name=t -c user.email=t@t commit -q --allow-empty -m lib
  git -C "$R" -c protocol.file.allow=always submodule add -q "$T/lib" sub 2>/dev/null
  gg "$R/sub" status --short
  assert_rc 0
}

test_guard_repo_appearing_in_plain_dir() {
  gg_setup "${FUNCNAME[0]}"
  mkdir -p "$T/plain"
  printf '%s\t%s\n' "$T/plain" none >> "$CFG/mounted-repos"
  gg "$T/plain" --version
  assert_rc 0
  # The agent makes the mounted directory a repository with its own config.
  git init -q "$T/plain"
  printf '[core]\n\tfsmonitor = "touch %s; false"\n' "$MARK" >> "$T/plain/.git/config"
  bare_git "$T/plain" status --short
  [[ -e "$MARK" ]] || fail "control: the attack did not work on plain git"
  rm -f "$MARK"
  gg "$T/plain" status --short
  assert_rc 1
  assert_out "had none when it was mounted"
  [[ -e "$MARK" ]] && fail "the agent's command ran"
}

test_guard_subdirectory_of_repo() {
  gg_setup "${FUNCNAME[0]}"
  mkdir -p "$R/sub"
  # Only the subdirectory was mounted.
  printf '%s\t%s\n' "$R/sub" "$R/.git" > "$CFG/mounted-repos"
  gg "$R/sub" status --short
  assert_rc 0
  git init -q "$R/sub"
  printf '[core]\n\tfsmonitor = "touch %s; false"\n' "$MARK" >> "$R/sub/.git/config"
  gg "$R/sub" status --short
  assert_rc 1
  [[ -e "$MARK" ]] && fail "the agent's command ran"
}

test_guard_worktree_config() {
  gg_setup "${FUNCNAME[0]}"
  git -C "$R" sparse-checkout init --cone >/dev/null 2>&1
  [[ "$(git -C "$R" config --get extensions.worktreeConfig)" == true ]] || fail "setup: sparse-checkout did not enable worktreeConfig"
  gg "$R" status --short
  assert_rc 0
  printf '[core]\n\tfsmonitor = "touch %s; false"\n' "$MARK" >> "$R/.git/config.worktree"
  bare_git "$R" status --short
  [[ -e "$MARK" ]] || fail "control: the attack did not work on plain git"
  rm -f "$MARK"
  gg "$R" status --short
  assert_rc 1
  assert_out "sets core.fsmonitor; only sparse-checkout settings"
  [[ -e "$MARK" ]] && fail "the agent's command ran"
}

test_session_records_git_dir_by_kind() {
  setup "${FUNCNAME[0]}"
  local main="$T/main" k
  git init -q -b main "$main"
  git -C "$main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
  git -C "$main" worktree add -q "$T/wt" 2>/dev/null
  mkdir -p "$main/sub" "$T/plain"
  for k in "$REPO" "$T/wt" "$main/sub" "$T/plain"; do
    REPO="$k"; ab_run --
    assert_rc 0
  done
  REPO="$T/repo"; ab_run --
  local list="$CFG/mounted-repos"
  assert_file_has "$list" "^$T/repo	$T/repo/.git\$"
  assert_file_has "$list" "^$T/wt	$main/.git\$"
  assert_file_has "$list" "^$main/sub	$main/.git\$"
  assert_file_has "$list" "^$T/plain	none\$"
  assert_eq "$(grep -c "^$T/repo	" "$list")" 1 "recorded once"
}

test_session_protects_git_dir() {
  setup "${FUNCNAME[0]}"
  ab_run --
  assert_rc 0
  local args; args="$(session_args)"
  grep -qx -- "$REPO/.git:/work/repo/.git:z" <<<"$args" || fail ".git not a mount of its own"
  grep -qx -- "$REPO/.git/modules:/work/repo/.git/modules:ro,z" <<<"$args" || fail "modules not read-only"
  assert_file_has "$CFG/mounted-repos" "^$REPO	$REPO/.git\$"
  assert_out "git on this host is not git-guard"
  ab_run --
  assert_eq "$(grep -c . "$CFG/mounted-repos")" 1 "repo recorded once"
}

# --- review 2: smaller fixes ---

test_config_trailing_comments() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana # dashboards" "GRAFANA_URL=\"https://g.example/#frag\"  # quoted, then a comment" \
         "AB_EGRESS=anthropic pypi	# tab before the comment"
  secrets grafana_sa
  ab_run --
  assert_rc 0
  assert_no_out "invalid"
  run_line ab-mcp-grafana | grep -q 'GRAFANA_URL=https://g.example/#frag ' || fail "value with # inside lost: $(run_line ab-mcp-grafana)"
  assert_file_lacks "$(cache squid-allow.conf)" 'golang'
}

test_update_every_must_be_a_number() {
  setup "${FUNCNAME[0]}"
  local v
  for v in "x[\$(touch $T/pwned)]" 6h; do
    : > "$CFG/config.env"; config "AB_UPDATE_EVERY=$v"
    ab_run --
    assert_rc 2
    assert_out "AB_UPDATE_EVERY must be a number of seconds"
  done
  [[ -e "$T/pwned" ]] && fail "the expression ran"
  grep -q '^podman' "$STUB_DIR/calls" && fail "podman called despite the error"
}

test_updates_every_must_be_a_number() {
  cu_setup "${FUNCNAME[0]}"
  touch "$T/home/.cache/agentbox.updates.checked" 2>/dev/null || { mkdir -p "$T/home/.cache"; touch "$T/home/.cache/agentbox.updates.checked"; }
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_UPDATE_EVERY="x[\$(touch $T/pwned)]" \
      bash "$AB/check-updates.sh" --if-due > "$T/out" 2>&1 < /dev/null
  RC=$?
  assert_rc 2
  [[ -e "$T/pwned" ]] && fail "the expression ran"
}

test_sync_refuses_odd_skill_names() {
  ss_setup "${FUNCNAME[0]}"
  mkdir -p "$SRC/eng/my skill"
  printf -- '---\nname: x\n---\n' > "$SRC/eng/my skill/SKILL.md"
  git -C "$SRC" add -A
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m odd
  ss_run
  assert_rc 1
  assert_out "the name must be letters, digits"
}

test_updates_read_records_like_run_sh() {
  cu_setup "${FUNCNAME[0]}"
  local old new
  old="$(printf 'a%.0s' {1..40})"; new="$(printf 'b%.0s' {1..40})"
  # A key twice, as after a manual edit: the last one counts, as in run.sh.
  printf '%s\n' "URL=https://github.com/acme/skills" "COMMIT=$old" "COMMIT=$new" \
    "SKILLS_ONLY=" "SKILLS_PREFIX=acme" "SOURCE=acme" "REF=" > "$CFG/skills/.sources/acme__skills"
  echo "$new" > "$T/remote_head"
  cu_run
  assert_no_out "update available: skills"
}

# --- releases: install, update with real SSH signatures, rollback --------

# KEY signs releases; $T/rel holds them; $T/api is a fake GitHub API.
rel_setup() {
  setup "$1"
  KEY="$T/key"
  ssh-keygen -q -t ed25519 -N '' -C test -f "$KEY"
  mkdir -p "$T/rel" "$T/home/.local/bin"
}
# make_release <version> [allowed key]: the current code as a release tree
# $T/rel/agentbox-<version>/, trusting KEY (or the given public key file).
make_release() {
  local v="$1" pubkey="${2:-$KEY.pub}" d="$T/rel/agentbox-$1"
  mkdir -p "$d"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$d")
  echo "$v" > "$d/VERSION"
  printf 'test namespaces="agentbox-release" %s\n' "$(cut -d' ' -f1,2 "$pubkey")" > "$d/release/allowed_signers"
  printf '## %s\n\n- changes of %s\n\n' "$v" "$v" > "$d/CHANGELOG.md"
}
# pack <version> [key]: archive and signature, and the API naming it latest.
pack() {
  local v="$1" key="${2:-$KEY}"
  tar -czf "$T/rel/agentbox-$v.tar.gz" -C "$T/rel" "agentbox-$v"
  rm -f "$T/rel/agentbox-$v.tar.gz.sig"
  ssh-keygen -q -Y sign -f "$key" -n agentbox-release "$T/rel/agentbox-$v.tar.gz"
  mkdir -p "$T/api/repos/kuza/agentbox/releases"
  printf '{"tag_name": "%s", "assets": [{"browser_download_url": "file://%s"}, {"browser_download_url": "file://%s"}]}\n' \
    "$v" "$T/rel/agentbox-$v.tar.gz" "$T/rel/agentbox-$v.tar.gz.sig" > "$T/api/repos/kuza/agentbox/releases/latest"
}
# ab_cmd <command> <args...>: with HOME in the scratch directory.
ab_cmd() {
  env HOME="$T/home" AB_RELEASE_API="file://$T/api" PATH="$T/home/.local/bin:$T/sysbin:$PATH" "$@" > "$T/out" 2>&1 < /dev/null
  RC=$?
}
current_version() { basename "$(readlink "$T/home/.local/share/agentbox/current")"; }

test_release_install() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh" --git-guard
  assert_rc 0
  assert_eq "$(current_version)" v1.0.0 "current"
  [[ -w "$T/home/.local/share/agentbox/versions/v1.0.0/run.sh" ]] && fail "installed version writable"
  [[ "$(readlink "$T/home/.local/bin/agentbox")" == "$T/home/.local/share/agentbox/current/agentbox" ]] || fail "command not linked"
  grep -q 'agentbox git-guard' "$T/home/.local/bin/git" || fail "git-guard not installed"
  local envf="$T/home/.config/environment.d/agentbox.conf"
  grep -qx 'PATH=$HOME/.local/bin:$PATH' "$envf" || fail "environment.d file not written"
  grep -qx 'GIT_CONFIG_KEY_0=core.fsmonitor' "$envf" || fail "fsmonitor not switched off"
  assert_out "log out and back in"
  [[ -f "$CFG/config.env" ]] || fail "config.env not created"
  local comp="$T/home/.local/share/bash-completion/completions/agentbox"
  [[ "$(readlink "$comp")" == "$T/home/.local/share/agentbox/current/completions/agentbox.bash" ]] || fail "completion not linked"
  [[ -f "$comp" ]] || fail "completion link broken"
  ab_cmd agentbox version
  assert_eq "$(cat "$T/out")" v1.0.0 "version"
  # A clone is no release.
  make_release v1.0.1; echo '$Format:%(describe:tags)$' > "$T/rel/agentbox-v1.0.1/VERSION"
  ab_cmd bash "$T/rel/agentbox-v1.0.1/install.sh"
  assert_rc 2
  assert_out "is a clone, not a release"
}

# An update from a version without the completion links it; a file of your
# own in its place stays.
test_release_completion_link() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  local comp="$T/home/.local/share/bash-completion/completions/agentbox"
  rm "$comp"
  make_release v1.1.0
  pack v1.1.0
  ab_cmd agentbox update --yes
  assert_rc 0
  [[ -f "$comp" ]] || fail "completion not linked by the update"
  # An update by an older version leaves no link: the new command makes it.
  rm "$comp"
  ab_cmd agentbox version
  [[ -f "$comp" ]] || fail "completion not linked by the command"
  rm "$comp"; echo "# mine" > "$comp"
  ab_cmd agentbox rollback
  ab_cmd agentbox version
  assert_eq "$(cat "$comp")" "# mine" "your completion file"
}

# Without git-guard no environment.d file; with it, an installed agentbox
# writes one at its next start, once: deleted, it stays deleted. A file or
# link that is there is never changed; uninstall removes only its own.
test_release_environment_file() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  local envf="$T/home/.config/environment.d/agentbox.conf"
  [[ -e "$envf" ]] && fail "written without git-guard"
  install -m 755 "$ROOT/git-guard" "$T/home/.local/bin/git"
  # Always ~/.config, whatever XDG_CONFIG_HOME a shell sets.
  ab_cmd env XDG_CONFIG_HOME="$T/elsewhere" agentbox version
  [[ -f "$envf" ]] || fail "not written by the command with git-guard there"
  [[ -e "$T/elsewhere/environment.d" ]] && fail "written under XDG_CONFIG_HOME"
  assert_out "log out and back in"
  # Deleted: not written again.
  rm "$envf"
  ab_cmd agentbox version
  [[ -e "$envf" ]] && fail "written again after you deleted it"
  # Its own file goes with uninstall.
  bash -c "source '$ROOT/lib/release.sh'; release_environment_content" > "$envf"
  ab_cmd agentbox uninstall --yes
  [[ -e "$envf" ]] && fail "agentbox's file left by uninstall"
  return 0
}

test_release_environment_file_yours() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  local envf="$T/home/.config/environment.d/agentbox.conf"
  mkdir -p "$(dirname "$envf")"
  # A dangling link is left alone, not followed.
  ln -s "$T/target" "$envf"
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh" --git-guard
  [[ -e "$T/target" ]] && fail "dangling link followed"
  rm "$envf"
  # A file of your own: kept, also by uninstall, which writes nothing first.
  echo "# mine" > "$envf"
  ab_cmd agentbox version
  assert_eq "$(cat "$envf")" "# mine" "your environment.d file"
  rm -f "$T/home/.local/share/agentbox/environment-written"; rm "$envf"
  ab_cmd agentbox uninstall --yes
  assert_no_out "log out and back in"
  [[ -e "$envf" ]] && fail "uninstall wrote the file first"
  echo "# mine" > "$envf"
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  ab_cmd agentbox uninstall --yes
  assert_eq "$(cat "$envf")" "# mine" "your file after uninstall"
  assert_out "kept .*not as agentbox wrote it"
}

# A file of yours there once: deleting it later does not bring agentbox's.
# agentbox's file with lines of yours added stays at uninstall.
test_release_environment_file_settled() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  local envf="$T/home/.config/environment.d/agentbox.conf"
  mkdir -p "$(dirname "$envf")"
  echo "# mine" > "$envf"
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh" --git-guard
  rm "$envf"
  ab_cmd agentbox version
  [[ -e "$envf" ]] && fail "written after you deleted your own"
  { bash -c "source '$ROOT/lib/release.sh'; release_environment_content"; echo "GIT_CONFIG_KEY_1=x"; } > "$envf"
  ab_cmd agentbox uninstall --yes
  grep -qx 'GIT_CONFIG_KEY_1=x' "$envf" || fail "your lines removed by uninstall"
  assert_out "kept .*not as agentbox wrote it"
}

# The README shows exactly what agentbox writes.
test_environment_file_in_readme() {
  local readme
  readme="$(awk '/^`~\/.local\/bin` must be first/ { on = 1 } on && /^```$/ { n++; next } on && n == 1 { print } n == 2 { exit }' "$ROOT/README.md")"
  assert_eq "$readme" "$(bash -c "source '$ROOT/lib/release.sh'; release_environment_content")" "README block"
}

test_release_install_keeps_your_git() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  printf '#!/bin/sh\n# my own git\n' > "$T/home/.local/bin/git"
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh" --git-guard
  assert_rc 0
  assert_out "is not git-guard; left as it is"
  grep -q 'my own git' "$T/home/.local/bin/git" || fail "your git replaced"
}

# GitHub's "latest" older than what runs: no downgrade, no nagging.
test_release_older_latest_not_offered() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.1.0
  ab_cmd bash "$T/rel/agentbox-v1.1.0/install.sh"
  make_release v1.0.0
  pack v1.0.0
  ab_cmd agentbox update --yes
  assert_rc 0
  assert_out "v1.1.0 is the latest release"
  assert_eq "$(current_version)" v1.1.0 "after update"
}

# No session mounts a file of agentbox's code itself: an installed version's
# files are read-only, podman cannot relabel them, and the agent could not
# read them (pi stopped on models.json). Copies from the cache instead.
test_session_mounts_no_code_files() {
  setup "${FUNCNAME[0]}"
  local agent src
  secrets openai_api_key llm_openai_caller
  for agent in claude pi; do
    ab_run AB_AGENT=$agent --
    assert_rc 0
    while IFS= read -r src; do
      [[ "$src" == "$AB"/* ]] && fail "$agent mounts $src from the code"
    done < <(session_args | awk 'prev == "-v" { split($0, a, ":"); print a[1] } { prev = $0 }')
  done
  session_args | grep -q "^$(cache session/pi)/models.json:/home/node/.pi/agent/models.json:ro,z\$" \
    || fail "pi's models.json not a copy from the cache"
  ab_run --
  session_args | grep -q "^$(cache session/claude)/statusline.py:/home/node/.claude/statusline.py:ro,z\$" \
    || fail "the status line not mounted from a copy"
  # A file of the code missing: the start stops and says so.
  rm "$AB/pi/models.json"
  ab_run AB_AGENT=pi --
  assert_rc 1
  assert_out "pi/models.json is missing"
}

# The single files a session may get are always mounted, a neutral one when
# there is nothing to put there: a mount leaves an empty, root-owned mount
# point in the home volume, which a session without it found in place of the
# file (pi without an API key stopped on models.json with EACCES).
test_session_optional_files_always_mounted() {
  setup "${FUNCNAME[0]}"
  local m
  optional_mount_of() { session_args | grep -- ":$1:ro,z\$" | cut -d: -f1; }
  ab_run AB_AGENT=pi --
  assert_rc 0
  m="$(optional_mount_of /home/node/.pi/agent/models.json)"
  [[ -n "$m" ]] || fail "models.json not mounted in subscription mode"
  assert_eq "$(cat "$m")" '{ "providers": {} }' "models.json without overrides"
  m="$(optional_mount_of /home/node/.pi/agent/AGENTS.md)"
  [[ -n "$m" && ! -s "$m" ]] || fail "AGENTS.md not mounted empty: '$m'"
  # A real file of the agent's under those mounts: a warning, as the home
  # is prepared (non-empty, not root's; the file stays).
  local calls; calls="$(tr '\n' ' ' < "$STUB_DIR/calls")"
  [[ "$calls" == *"-e AB_COVERED=.pi/agent/models.json .pi/agent/AGENTS.md "* ]] || fail "covered files not checked"
  [[ "$calls" == *'[ -s "$f" ] && [ "$(stat -c %u "$f")" != 0 ]'* ]] || fail "not limited to real files"
  ab_run --
  assert_rc 0
  m="$(optional_mount_of /home/node/.claude/CLAUDE.md)"
  [[ -n "$m" && ! -s "$m" ]] || fail "CLAUDE.md not mounted empty: '$m'"
  m="$(optional_mount_of /home/node/.claude/statusline.py)"
  cmp -s "$m" "$AB/claude/statusline.py" || fail "status line mount is not a copy of claude/statusline.py: '$m'"
  # With your AGENTS.md and an API key: those.
  echo "# rules" > "$CFG/AGENTS.md"
  secrets openai_api_key llm_openai_caller
  ab_run AB_AGENT=pi --
  assert_rc 0
  assert_eq "$(optional_mount_of /home/node/.pi/agent/AGENTS.md)" "$CFG/AGENTS.md" "your AGENTS.md"
  assert_eq "$(cat "$(optional_mount_of /home/node/.pi/agent/models.json)")" "$(cat "$AB/pi/models.json")" "models.json of API-key mode"
}

test_banner_of_a_release() {
  setup "${FUNCNAME[0]}"
  echo v1.0.0 > "$AB/VERSION"
  ab_run --
  assert_rc 0
  assert_eq "$(head -n1 "$T/out")" "agentbox v1.0.0" "banner of a release"
}

# An update over skipped releases shows each one's changes, not the
# installed one's.
test_release_update_shows_skipped() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  make_release v1.2.0
  # Out of order, one with a date after the version, one twice.
  printf '%s\n' '# Changelog' '' '## v1.1.0 (2026-11-01)' '' '- changes of v1.1.0' '' '## v1.2.0' '' '- changes of v1.2.0' '' \
    '## v1.0.0' '' '- changes of v1.0.0' '' '## v1.1.0' '' '- the same again' > "$T/rel/agentbox-v1.2.0/CHANGELOG.md"
  pack v1.2.0
  ab_cmd agentbox update --yes
  assert_rc 0
  assert_out "changes of v1.2.0"
  assert_out "changes of v1.1.0"
  assert_no_out "changes of v1.0.0"
  assert_no_out "the same again"
  [[ "$(grep -n 'changes of v1.2.0' "$T/out" | cut -d: -f1)" -lt "$(grep -n 'changes of v1.1.0' "$T/out" | cut -d: -f1)" ]] \
    || fail "not newest first"
  # No section in the range: the new release's own, as before.
  ab_cmd agentbox rollback
  printf '%s\n' '## v9.9.9' '' '- something else' > "$T/rel/agentbox-v1.2.0/CHANGELOG.md"
  pack v1.2.0
  ab_cmd agentbox update --yes
  assert_rc 0
  assert_out "v1.0.0 -> v1.2.0"
}

test_release_missing_asset() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  make_release v1.1.0
  pack v1.1.0
  sed -i 's#, {"browser_download_url": "[^"]*\.sig"}##' "$T/api/repos/kuza/agentbox/releases/latest"
  ab_cmd agentbox update --yes
  assert_rc 1
  assert_out "could not find the latest release"
}

# An interrupted install leaves versions/<v>.tmp: the next one still works.
test_release_install_after_interrupted_one() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  mkdir -p "$T/home/.local/share/agentbox/versions/v1.0.0.tmp/half"
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  assert_rc 0
  ab_cmd agentbox version
  assert_eq "$(cat "$T/out")" v1.0.0 "version"
  [[ -e "$T/home/.local/share/agentbox/versions/v1.0.0/half" ]] && fail "the leftover went into the version"
  return 0
}

# What Tab offers, word by word.
test_completion() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$T/cwd/proj" "$T/cwd/pics"
  comp() {  # <words...>: COMPREPLY for the last word, sorted, on one line
    (cd "$T/cwd" && bash -c '
      source "$1"; shift
      COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 ))
      _agentbox; printf "%s\n" "${COMPREPLY[@]}" | sort | paste -sd" "' _ "$ROOT/completions/agentbox.bash" "$@")
  }
  assert_eq "$(comp agentbox "")" "login pi pics proj rollback setup shell uninstall update version" "first word"
  assert_eq "$(comp agentbox p)" "pi pics proj" "first word, p"
  assert_eq "$(comp agentbox pi "")" "pics proj" "after pi"
  assert_eq "$(comp agentbox uninstall --)" "--all --yes" "after uninstall"
  assert_eq "$(comp agentbox update "")" "--yes" "after update"
  assert_eq "$(comp agentbox version "")" "" "after version"
}

test_release_update_and_rollback() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  make_release v1.1.0
  pack v1.1.0
  ab_cmd agentbox update --yes
  assert_rc 0
  assert_out "v1.0.0 -> v1.1.0 \(signature verified\)"
  assert_out "changes of v1.1.0"
  assert_eq "$(current_version)" v1.1.0 "after update"
  assert_eq "$(cat "$T/home/.local/share/agentbox/previous")" v1.0.0 "previous"
  ab_cmd agentbox update --yes
  assert_out "v1.1.0 is the latest release"
  ab_cmd agentbox rollback
  assert_rc 0
  assert_eq "$(current_version)" v1.0.0 "after rollback"
  # Without a terminal and without --yes nothing is installed.
  ab_cmd agentbox update
  assert_out "not installed"
  assert_eq "$(current_version)" v1.0.0 "update without confirmation"
}

test_release_update_rejects_tampered_archive() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  make_release v1.1.0
  pack v1.1.0
  # Changed after signing: the signature no longer matches.
  echo 'echo pwned' >> "$T/rel/agentbox-v1.1.0/run.sh"
  tar -czf "$T/rel/agentbox-v1.1.0.tar.gz" -C "$T/rel" agentbox-v1.1.0
  ab_cmd agentbox update --yes
  assert_rc 1
  assert_out "does not verify"
  assert_eq "$(current_version)" v1.0.0 "current after a rejected update"
  [[ -e "$T/home/.local/share/agentbox/versions/v1.1.0" ]] && fail "rejected release unpacked into versions/"
}

test_release_update_rejects_unknown_key() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  ssh-keygen -q -t ed25519 -N '' -C other -f "$T/other"
  # The new release even names the other key as trusted: that counts only
  # once a release signed by a trusted key brings it.
  make_release v1.1.0 "$T/other.pub"
  pack v1.1.0 "$T/other"
  ab_cmd agentbox update --yes
  assert_rc 1
  assert_out "does not verify"
  assert_eq "$(current_version)" v1.0.0 "current"
}

test_release_update_needs_installed_copy() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/agentbox" update --yes
  assert_rc 2
  assert_out "not an installed version"
}

test_uninstall() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh" --git-guard
  echo "AB_SERVICES=redis" >> "$CFG/config.env"
  echo "GH_OWNERS=MyOrg" >> "$CFG/config.env"
  printf '%s\n' "ab-mcp-grafana x" "ab-claude-7 localhost/agentbox" "redis docker.io/library/redis:7" > "$STUB_DIR/running"
  printf '%s\n' ab-claude-home ab-cache mydata > "$STUB_DIR/volumes"
  printf '%s\n' ab-internal ab-services podman > "$STUB_DIR/networks"
  printf '%s\n' "ab-services redis" "ab-services ab-claude-7" > "$STUB_DIR/netconns"
  printf '%s\n' claude_oauth grafana_sa grafana_mcp_caller tabularis_bridge_key github_pat_myorg github_pat_ci mine > "$STUB_DIR/secrets"
  printf '%s\n' "agentbox-mcp-tabularis.service agentbox host service [abc]" "agentbox-mine.service my own" > "$STUB_DIR/units"
  # A module of yours: indented, in single quotes, ${VAR}.
  mkdir -p "$CFG/mcp.local/mine"
  printf '%s\n' "  MINE_IMAGE='ghcr.io/me/mine:1'" "  MCP_IMAGES=(\"\${MINE_IMAGE}\" 'ghcr.io/me/other:2')" > "$CFG/mcp.local/mine/mcp.sh"
  mkdir -p "$T/home/.cache/agentbox"
  echo "localhost/agentbox old-image-id" > "$T/home/.cache/agentbox/retired-images"
  : > "$STUB_DIR/calls"
  env HOME="$T/home" PATH="$T/bin:$PATH" "$T/home/.local/bin/agentbox" uninstall --yes > "$T/out" 2>&1 < /dev/null
  RC=$?
  assert_rc 0
  assert_eq "$(started)" "redis" "containers left"
  assert_eq "$(paste -sd' ' "$STUB_DIR/volumes")" "mydata" "volumes left"
  assert_eq "$(paste -sd' ' "$STUB_DIR/networks")" "podman" "networks left"
  grep -qx 'podman network disconnect ab-services redis' "$STUB_DIR/calls" || fail "redis not disconnected"
  grep -q '^podman network rm -f' "$STUB_DIR/calls" && fail "network rm -f would remove your containers"
  grep -qx 'podman rmi old-image-id' "$STUB_DIR/calls" || fail "replaced image left behind"
  local img
  for img in docker.io/grafana/mcp-grafana:latest docker.io/bytebase/dbhub:1.5.0 ghcr.io/rtuszik/woodpecker-mcp:0.5.3 \
             ghcr.io/me/mine:1 ghcr.io/me/other:2; do
    grep -qx "podman rmi $img" "$STUB_DIR/calls" || fail "module image $img left behind"
  done
  assert_eq "$(paste -sd' ' "$STUB_DIR/secrets")" "claude_oauth grafana_sa grafana_mcp_caller tabularis_bridge_key github_pat_myorg github_pat_ci mine" "secrets kept"
  assert_eq "$(awk '{ print $1 }' "$STUB_DIR/units")" "agentbox-mine.service" "host services left"
  [[ -e "$T/home/.local/share/agentbox" ]] && fail "installed versions left"
  [[ -e "$T/home/.local/bin/agentbox" || -e "$T/home/.local/bin/git" ]] && fail "command or git-guard left"
  [[ -L "$T/home/.local/share/bash-completion/completions/agentbox" ]] && fail "completion left"
  [[ -e "$T/home/.cache/agentbox" ]] && fail "cache left"
  [[ -f "$CFG/config.env" ]] || fail "your files removed without --all"
  # --all: the secrets agentbox and its modules use, and your files.
  : > "$STUB_DIR/calls"
  env HOME="$T/home" PATH="$T/bin:$PATH" bash "$T/rel/agentbox-v1.0.0/agentbox" uninstall --yes --all > "$T/out" 2>&1 < /dev/null
  RC=$?
  assert_rc 0
  # The secret of an owner in GH_OWNERS goes; one of the same prefix that
  # agentbox does not use stays.
  assert_eq "$(paste -sd' ' "$STUB_DIR/secrets")" "github_pat_ci mine" "secrets after --all"
  [[ -e "$CFG" ]] && fail "your files left after --all"
}

test_uninstall_asks() {
  rel_setup "${FUNCNAME[0]}"
  make_release v1.0.0
  ab_cmd bash "$T/rel/agentbox-v1.0.0/install.sh"
  echo "ab-mcp-grafana x" > "$STUB_DIR/running"
  # No terminal, no --yes: nothing goes.
  env HOME="$T/home" PATH="$T/bin:$PATH" "$T/home/.local/bin/agentbox" uninstall > "$T/out" 2>&1 < /dev/null
  RC=$?
  assert_rc 0
  assert_out "nothing removed"
  assert_eq "$(started)" "ab-mcp-grafana" "containers"
  [[ -e "$T/home/.local/share/agentbox/current" ]] || fail "removed without confirmation"
}

# --- agentbox login: a real terminal through script(1) ---

# tty_run <input> <env...> -- <run.sh args...>: run.sh on a pseudo-terminal,
# <input> typed into it; a "\p" in it waits a second before the rest, as a
# person would (agent_login reads on what comes right after a token).
tty_run() {
  local input="$1"; shift
  local envs=()
  while (( $# )) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  : > "$STUB_DIR/calls"
  # timeout: a question the input does not answer fails the test, not the run.
  local part
  { while [[ "$input" == *'\p'* ]]; do
      part="${input%%\\p*}"; printf '%b' "$part"; sleep 1; input="${input#*\\p}"
    done
    printf '%b' "$input"; } | timeout 60 script -qec "$(printf '%q ' env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" \
      PATH="$T/bin:$PATH" STUB_DIR="$STUB_DIR" AB_CHECK_UPDATES=0 ${envs[@]+"${envs[@]}"} bash "$AB/run.sh" "$@")" /dev/null \
      > "$T/out" 2>&1
  RC=$?
}

test_login() {
  command -v script >/dev/null || return 0
  setup "${FUNCNAME[0]}"
  : > "$STUB_DIR/secrets"
  tty_run 'sk-ant-oat01-abc123\n' AB_LOGIN=1 --
  assert_rc 0
  assert_out "token stored as the podman secret claude_oauth"
  grep -q 'podman run --rm -it .* localhost/agentbox setup-token' "$STUB_DIR/calls" || fail "setup-token not run"
  assert_eq "$(cat "$STUB_DIR/secret-claude_oauth")" sk-ant-oat01-abc123 "stored token"
  grep -q '^podman run --rm -i .*--name ab-claude' "$STUB_DIR/calls" && fail "a session started"
  # The browser's code is not the token: nothing stored.
  tty_run 'Xy7_browser-code\n' AB_LOGIN=1 --
  assert_rc 1
  assert_out "that is not the token"
  assert_eq "$(cat "$STUB_DIR/secret-claude_oauth")" sk-ant-oat01-abc123 "token after a wrong paste"
  # A token wrapped over two lines arrives in one paste: all of it is kept.
  tty_run 'sk-ant-oat01-abc\ndef456\n' AB_LOGIN=1 --
  assert_rc 0
  assert_eq "$(cat "$STUB_DIR/secret-claude_oauth")" sk-ant-oat01-abcdef456 "token over two lines"
  # Another agent: the message names it.
  ab_run AB_LOGIN=1 AB_AGENT=shell --
  assert_rc 2
  assert_out "but AB_AGENT is shell"
  # podman before 4.7 has no secret create --replace.
  tty_run 'sk-ant-oat01-new\n' AB_LOGIN=1 STUB_OLD_PODMAN=1 --
  assert_rc 0
  assert_eq "$(cat "$STUB_DIR/secret-claude_oauth")" sk-ant-oat01-new "token replaced on old podman"
  # Login needs no squid image, so it does not build one.
  echo "localhost/agentbox-squid old" >> "$STUB_DIR/image_labels"
  tty_run 'sk-ant-oat01-new\n' AB_LOGIN=1 --
  grep -q '^podman build.*agentbox-squid' "$STUB_DIR/calls" && fail "login built squid"
  return 0
}

test_first_start_offers_login() {
  command -v script >/dev/null || return 0
  setup "${FUNCNAME[0]}"
  : > "$STUB_DIR/secrets"
  # The last Enter: the warnings of the start, then "start the session?".
  tty_run 'y\nsk-ant-oat01-first\n\p\n' --
  assert_rc 0
  assert_out "no Claude Code token yet"
  assert_eq "$(cat "$STUB_DIR/secret-claude_oauth" 2>/dev/null)" sk-ant-oat01-first "stored token"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "the session did not start after the sign-in"
  # Saying no stops with the usual error.
  : > "$STUB_DIR/secrets"
  tty_run 'n\n' --
  assert_rc 1
  assert_out "missing podman secrets: claude_oauth"
}

# --- Trivy ---

test_trivy() {
  setup "${FUNCNAME[0]}"
  ab_run --
  grep -qE 'entrypoint trivy|ab-trivy|WITH_TRIVY' "$STUB_DIR/calls" && fail "Trivy used without AB_TRIVY"
  config "AB_TRIVY=1"
  ab_run AB_UPGRADE=1 --
  assert_rc 0
  grep -q '^podman build .*--build-arg WITH_TRIVY=1' "$STUB_DIR/calls" || fail "image built without Trivy"
  grep -q '^podman run --rm --network ab-egress .* -v ab-trivy:/home/node/.cache/trivy --entrypoint trivy localhost/agentbox image --download-db-only' "$STUB_DIR/calls" \
    || fail "database not updated outside the session"
  local args; args="$(session_args)"
  grep -qx 'ab-trivy:/home/node/.cache/trivy:ro' <<<"$args" || fail "database not read-only in the session"
  grep -qx 'TRIVY_SKIP_DB_UPDATE=true' <<<"$args" || fail "session may download"
  grep -qx 'TRIVY_SKIP_JAVA_DB_UPDATE=true' <<<"$args" || fail "Java database not switched off"
  grep -qx 'TRIVY_DISABLE_TELEMETRY=true' <<<"$args" || fail "telemetry not switched off in the session"
  grep -q 'download-db-only .*--disable-telemetry' "$STUB_DIR/calls" || fail "telemetry not switched off for the update"
  # Within UPDATE_EVERY: no new download.
  ab_run --
  grep -q 'download-db-only' "$STUB_DIR/calls" && fail "database downloaded again within the interval"
  # A removed volume holds no database, however fresh the stamp.
  echo ab-trivy > "$STUB_DIR/volumes_absent"
  ab_run --
  grep -q 'download-db-only' "$STUB_DIR/calls" || fail "database not fetched into a removed volume"
  : > "$STUB_DIR/volumes_absent"
  # An image without Trivy: a clear error.
  ab_run AB_UPDATE=1 STUB_NO_TRIVY=1 --
  assert_rc 1
  assert_out "has no Trivy; rebuild it"
}

# --- squid built here ---

# An image from before the label agentbox.pulled: a rebuild for a setting
# takes its build date as the pull date.
test_image_pulled_date_from_older_image() {
  setup "${FUNCNAME[0]}"
  echo "localhost/agentbox older-fingerprint" > "$STUB_DIR/image_labels"
  ab_run STUB_IMAGE_CREATED=1700000000 --
  assert_rc 0
  grep -q '^podman build.*--label agentbox.pulled=1700000000 -t localhost/agentbox ' "$STUB_DIR/calls" \
    || fail "build date not carried over: $(grep 'podman build' "$STUB_DIR/calls")"
}

test_squid_built_here() {
  setup "${FUNCNAME[0]}"
  ab_run --
  assert_rc 0
  run_line ab-egress | grep -q ' localhost/agentbox-squid$' || fail "egress not on the local squid image: $(run_line ab-egress)"
  grep -q 'pull .*squid' "$STUB_DIR/calls" && fail "squid pulled from a registry"
  ab_run AB_UPGRADE=1 --
  assert_rc 0
  grep -q '^podman build --layers=false --pull --no-cache --label agentbox.build=[0-9a-f]* --label agentbox.pulled=[0-9]* -t localhost/agentbox-squid -f .*/Containerfile.squid ' "$STUB_DIR/calls" \
    || fail "squid not rebuilt on AB_UPGRADE: $(grep 'podman build' "$STUB_DIR/calls")"
}

# The ubuntu/squid image goes only when agentbox's own ab-egress moves off
# it; one that is just there may be yours.
test_old_squid_image_removed() {
  setup "${FUNCNAME[0]}"
  touch "$STUB_DIR/old_squid"
  ab_run --
  assert_rc 0
  grep -q 'rmi .*ubuntu/squid' "$STUB_DIR/calls" && fail "an ubuntu/squid not used by agentbox removed"
  # An ab-egress from before agentbox built its own squid.
  sed -i 's#^ab-egress .*#ab-egress docker.io/ubuntu/squid:latest#' "$STUB_DIR/running"
  ab_run --
  assert_rc 0
  assert_out "docker.io/ubuntu/squid:latest is no longer used"
  run_line ab-egress | grep -q ' localhost/agentbox-squid$' || fail "ab-egress not moved to the local squid"
  grep -qx 'podman rmi docker.io/ubuntu/squid:latest' "$STUB_DIR/calls" || fail "old squid image not removed by name"
  ab_run --
  assert_no_out "ubuntu/squid"
}

test_updates_local_images_age() {
  cu_setup "${FUNCNAME[0]}"
  echo "ab-egress localhost/agentbox-squid" >> "$STUB_DIR/running"
  # Built 40 days ago: a reminder; no registry is asked for a local image.
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" \
      STUB_IMAGE_CREATED="$(( $(date +%s) - 40 * 86400 ))" bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_out "image localhost/agentbox-squid was built on a base pulled 40 days ago"
  assert_out "image localhost/agentbox was built on a base pulled 40 days ago"
  grep -q 'localhost' "$T/urls" 2>/dev/null && fail "registry asked about a local image"
  # An image a module built here (mcp/bb4): reminded too.
  echo "localhost/agentbox-bb4-devtools abc" >> "$STUB_DIR/image_labels"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" \
      STUB_IMAGE_CREATED="$(( $(date +%s) - 40 * 86400 ))" bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_out "image localhost/agentbox-bb4-devtools was built on a base pulled 40 days ago"
  sed -i '/agentbox-bb4-devtools/d' "$STUB_DIR/image_labels"
  # Rebuilt today for a setting, on a base pulled 40 days ago: still reminded.
  echo "localhost/agentbox $(( $(date +%s) - 40 * 86400 ))" > "$STUB_DIR/image_pulled"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" \
      STUB_IMAGE_CREATED="$(date +%s)" bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_out "image localhost/agentbox was built on a base pulled 40 days ago"
  assert_no_out "localhost/agentbox-squid was built"
  assert_no_out "could not check localhost"
}

test_image_rebuilt_when_its_build_changes() {
  setup "${FUNCNAME[0]}"
  ab_run AB_UPGRADE=1 --
  : > "$STUB_DIR/calls"
  ab_run --
  assert_rc 0
  grep -q '^podman build' "$STUB_DIR/calls" && fail "rebuilt without a change"
  # A build setting: only the agentbox image, a cached build, the old one retired.
  config "AB_TRIVY=1"
  ab_run STUB_BUILT_ID=img-2 --
  assert_rc 0
  assert_out "localhost/agentbox was built from another Containerfile or build settings; rebuilding"
  grep -q '^podman build --layers=false .*--build-arg WITH_TRIVY=1 --label agentbox.build=[0-9a-f]* .*-t localhost/agentbox ' "$STUB_DIR/calls" \
    || fail "not rebuilt with Trivy: $(grep 'podman build' "$STUB_DIR/calls")"
  grep -q '^podman build.*--pull' "$STUB_DIR/calls" && fail "a settings rebuild pulled"
  # It keeps the date the base image was pulled, for the age reminder.
  local pulled; pulled="$(awk '$1 == "localhost/agentbox" { print $2 }' "$STUB_DIR/image_pulled")"
  grep -q "^podman build.*--label agentbox.pulled=$pulled -t localhost/agentbox " "$STUB_DIR/calls" \
    || fail "pull date not kept: $(grep 'podman build' "$STUB_DIR/calls")"
  grep -q '^podman build.*agentbox-squid' "$STUB_DIR/calls" && fail "squid rebuilt for an agentbox setting"
  grep -q '^podman rmi img-1$' "$STUB_DIR/calls" || fail "old image not removed"
  : > "$STUB_DIR/calls"
  ab_run --
  grep -q '^podman build' "$STUB_DIR/calls" && fail "rebuilt again without a change"
  # A changed Containerfile.squid: only squid.
  echo "# changed" >> "$AB/Containerfile.squid"
  ab_run --
  grep -q '^podman build.*-t localhost/agentbox-squid ' "$STUB_DIR/calls" || fail "squid not rebuilt after its Containerfile changed"
  grep -q '^podman build.*-t localhost/agentbox ' "$STUB_DIR/calls" && fail "agentbox rebuilt for a squid change"
  return 0
}

# --- agentbox setup ---

# setup_run <input>: agentbox setup with <input> on stdin; output in $T/out.
setup_run() {
  printf '%b' "$1" | env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" \
    bash "$AB/agentbox" setup > "$T/out" 2>&1
  RC=$?
}
setup_entry() {  # <name>: its number in the menu
  printf 'q\n' | env HOME="$T/home" PATH="$T/bin:$PATH" bash "$AB/agentbox" setup 2>/dev/null \
    | awk -v n="$1" '$1 ~ /^[0-9]+$/ { for (i = 2; i <= NF; i++) if ($i == n || index($i, n ":") == 1 || index($i, n "=") == 1) { print $1; exit } }'
}

test_setup_edits_config() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/agentbox" "$AB/"
  cp "$ROOT/config.env.example" "$AB/"
  printf '%s\n' '# mine' 'AB_MCP=graylog # my note' 'GRAYLOG_URL=https://g.example' '#AB_TRIVY=1' > "$CFG/config.env"
  # Under a module: its settings and secrets, and how to change them.
  mkdir -p "$CFG/egress.local.d"; echo 'hosts = ["corp.example"]  # mine' > "$CFG/egress.local.d/corp.toml"
  echo 'hostz = ["x.example"]' > "$CFG/egress.local.d/typo.toml"
  mkdir -p "$CFG/skills.local.d"; echo "url = 'https://example.com/me/skills'" > "$CFG/skills.local.d/mine.toml"
  setup_run "q\n"
  # A skill source by its URL, from the shared .toml files and yours.
  assert_out '\[ \] mattpocock +https://github.com/mattpocock/skills$'
  assert_out '\[ \] mine +\(yours\) https://example.com/me/skills$'
  # An egress group by its hosts, from the shared .toml files and yours; a
  # bad group by its first error.
  assert_out '\[x\] pypi +pypi.org files.pythonhosted.org$'
  assert_out '\[ \] corp +\(yours\) corp.example$'
  assert_out "\\[ \\] typo +\\(yours\\) \\(typo.toml:1: unknown key 'hostz'"
  assert_out "GRAYLOG_URL=https://g.example · secret graylog_basic: MISSING · e [0-9]"
  assert_out "GRAFANA_URL NEEDED · secret grafana_sa: MISSING · e [0-9]"
  assert_out "TABULARIS_CMD \\(default\\) · TABULARIS_PORT \\(default\\) · e [0-9]"
  secrets graylog_basic
  local grafana trivy services
  grafana="$(setup_entry grafana)"; trivy="$(setup_entry AB_TRIVY)"; services="$(setup_entry AB_SERVICES)"
  [[ -n "$grafana" && -n "$trivy" && -n "$services" ]] || fail "entries not found: '$grafana' '$trivy' '$services'"
  # grafana on: its URL (required) and its token; Trivy on; a value with " #".
  setup_run "$grafana\n\nhttps://grafana.example\nsa-token\n$trivy\n$services\nredis # db\ns\n"
  assert_rc 0
  assert_out "GRAFANA_URL is needed"
  assert_out "stored the Podman secret grafana_sa"
  assert_eq "$(cat "$STUB_DIR/secret-grafana_sa")" sa-token "token"
  assert_eq "$(cat "$CFG/config.env")" "# mine
AB_MCP=graylog grafana # my note
GRAYLOG_URL=https://g.example
#AB_TRIVY=1
AB_TRIVY=1
AB_SERVICES=\"redis # db\"
GRAFANA_URL=https://grafana.example" "config.env"
  assert_eq "$(head -n2 "$CFG/config.env.bak" | tail -n1)" "AB_MCP=graylog # my note" "backup"
  # run.sh reads it as written: grafana with its URL and secret, Trivy.
  ab_run --
  assert_rc 0
  run_line ab-mcp-grafana | grep -q 'https://grafana.example' || fail "grafana not started from the saved settings"
  session_args | grep -qx 'TRIVY_SKIP_DB_UPDATE=true' || fail "Trivy setting not read"
  # Off again: the line stays, without grafana; Trivy commented out.
  setup_run "$grafana\n$trivy\ns\n"
  grep -qx 'AB_MCP=graylog # my note' "$CFG/config.env" || fail "grafana not removed: $(grep AB_MCP "$CFG/config.env")"
  grep -qx '#AB_TRIVY=1' "$CFG/config.env" || fail "Trivy not off"
  grep -qx 'AB_TRIVY=1' "$CFG/config.env" && fail "Trivy still on"
  return 0
}

test_setup_quit_and_new_config() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/agentbox" "$ROOT/config.env.example" "$AB/"
  echo "AB_MCP=" > "$CFG/config.env"
  local grafana; grafana="$(setup_entry grafana)"
  # Changes, then q and yes: nothing written, no secret.
  setup_run "$grafana\nhttps://grafana.example\nsa-token\nq\ny\n"
  assert_eq "$(cat "$CFG/config.env")" "AB_MCP=" "config.env after quitting"
  [[ -e "$STUB_DIR/secret-grafana_sa" ]] && fail "secret created without saving"
  # No config.env yet: made from the example, then edited.
  rm "$CFG/config.env"
  setup_run "$grafana\nhttps://grafana.example\n\ns\n"
  assert_rc 0
  grep -qx 'AB_MCP=grafana' "$CFG/config.env" || fail "AB_MCP not set in the new file"
  grep -q '^# agentbox settings' "$CFG/config.env" || fail "not made from the example"
}

# Secrets through the menu: a module makes the value from what you type
# (graylog: base64 of <token>:token); e replaces one that exists, Enter
# keeps it; spaces inside stay.
test_setup_secrets() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/agentbox" "$ROOT/config.env.example" "$AB/"
  echo "AB_MCP=" > "$CFG/config.env"
  local graylog grafana
  graylog="$(setup_entry graylog)"; grafana="$(setup_entry grafana)"
  setup_run "$graylog\nhttps://g.example\n glt_abc \ns\n"
  assert_rc 0
  assert_out "a Graylog API token of a read-only user"
  assert_eq "$(cat "$STUB_DIR/secret-graylog_basic")" "$(printf 'glt_abc:token' | base64 -w0)" "graylog secret"
  # e: the stored secret is replaced only for a new value.
  setup_run "e $graylog\n\n\ns\n"
  assert_out "secret graylog_basic is stored; a new value replaces it"
  assert_out "nothing to save"
  setup_run "e $graylog\n\nglt new\ns\n"
  assert_eq "$(cat "$STUB_DIR/secret-graylog_basic")" "$(printf 'glt new:token' | base64 -w0)" "replaced secret"
  # On, settings and token typed, off again: none of it is saved.
  setup_run "$grafana\nhttps://grafana.example\nsa-token\n$grafana\ns\n"
  [[ -e "$STUB_DIR/secret-grafana_sa" ]] && fail "secret of a module turned off stored"
  grep -q GRAFANA_URL "$CFG/config.env" && fail "setting of a module turned off saved"
  # github: the secret of an owner typed into GH_OWNERS is asked for at once.
  local github; github="$(setup_entry github)"
  setup_run "$github\n\nacme\nghp_main\nghp_acme\ns\n"
  assert_out "secret github_pat_acme for github \(a fine-grained personal access token with resource owner acme"
  grep -qx 'GH_OWNERS=acme' "$CFG/config.env" || fail "GH_OWNERS not saved"
  assert_eq "$(cat "$STUB_DIR/secret-github_pat_acme")" "ghp_acme" "owner secret"
  # The token of an owner in config.env shows as MISSING at once, before
  # any change in the menu.
  rm -f "$STUB_DIR/secret-github_pat_acme"; sed -i '/^github_pat_acme$/d' "$STUB_DIR/secrets"
  setup_run "q\n"
  assert_out "secret github_pat_acme: MISSING"
  # An owner typed, its token typed, then the owner changed: that token is
  # not stored, and the save says so.
  rm -f "$STUB_DIR/secret-github_pat_old"
  setup_run "e $github\n\nold\n\nghp_old\ne $github\n\nacme\n\n\ns\n"
  [[ -e "$STUB_DIR/secret-github_pat_old" ]] && fail "the token of a dropped owner stored"
  assert_out "not storing the Podman secret github_pat_old"
  # e on an entry that is not a module changes nothing.
  local anthropic; anthropic="$(setup_entry anthropic)"
  setup_run "e $anthropic\ns\n"
  assert_out "e is for MCP modules"
  assert_out "nothing to save"
  return 0
}

# A config.env that is a link stays one; a module setting in the
# environment counts, and is named.
test_setup_link_and_environment() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/agentbox" "$ROOT/config.env.example" "$AB/"
  mkdir -p "$T/dotfiles"
  echo "AB_MCP=" > "$T/dotfiles/agentbox.env"
  ln -sf "$T/dotfiles/agentbox.env" "$CFG/config.env"
  local grafana; grafana="$(setup_entry grafana)"
  printf '%b' "$grafana\n\n\ns\n" | env HOME="$T/home" PATH="$T/bin:$PATH" GRAFANA_URL=https://env.example \
    bash "$AB/agentbox" setup > "$T/out" 2>&1
  assert_out "GRAFANA_URL=https://env.example \\(environment\\)"
  assert_out "Note: set in your environment, which wins over config.env: GRAFANA_URL"
  assert_no_out "GRAFANA_URL is needed"
  [[ -L "$CFG/config.env" ]] || fail "the link became a file"
  grep -qx 'AB_MCP=grafana' "$T/dotfiles/agentbox.env" || fail "the linked file not edited"
}

# Values trimmed, a quoted value kept quoted; a name run.sh would reject
# cannot be turned on; loose input is read right; a first save that fails
# leaves no config.env.
test_setup_values_names_input() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/agentbox" "$ROOT/config.env.example" "$AB/"
  echo "AB_MCP=" > "$CFG/config.env"
  mkdir -p "$CFG/egress.local.d"; echo 'hosts = ["corp.example"]' > "$CFG/egress.local.d/corp.net.toml"
  local services forward corp graylog
  services="$(setup_entry AB_SERVICES)"; forward="$(setup_entry AB_FORWARD)"
  corp="$(setup_entry corp.net)"; graylog="$(setup_entry graylog)"
  setup_run " $services \n  redis  \n$forward\n\"db=x:1\"\n$corp\ne 1 2\ns\n"
  assert_out "corp.net .*cannot be used"
  assert_out "'corp.net' cannot be used"
  assert_out "a number, e <number>, s or q"
  grep -qx 'AB_SERVICES=redis' "$CFG/config.env" || fail "value not trimmed: $(grep AB_SERVICES "$CFG/config.env")"
  grep -qx "AB_FORWARD='\"db=x:1\"'" "$CFG/config.env" || fail "quoted value: $(grep AB_FORWARD "$CFG/config.env")"
  grep -q corp "$CFG/config.env" && fail "a rejected name saved"
  # Only a secret typed: the menu says so, and calls it not saved yet.
  setup_run "e $graylog\nhttps://g.example\ntok\ne $graylog\n\n\nq\ny\n"
  assert_out "(changed, not saved)"
  assert_out "secret graylog_basic is entered, not saved yet"
  # An unset AB_EGRESS toggled off and on again stays unset.
  local openai; openai="$(setup_entry openai)"
  setup_run "$openai\n$openai\ns\n"
  assert_out "nothing to save"
  grep -q '^AB_EGRESS' "$CFG/config.env" && fail "AB_EGRESS pinned"
  # A file name with a space is one name, and cannot be used; a module that
  # cannot be read cannot be turned on.
  echo 'hosts = ["x"]' > "$CFG/egress.local.d/my group.toml"
  mkdir -p "$CFG/mcp.local/broken"; echo 'MCP_DESCRIPTION=x; if' > "$CFG/mcp.local/broken/mcp.sh"
  local broken; broken="$(setup_entry broken)"
  setup_run "$broken\ns\n"
  assert_out "my group .*cannot be used"
  assert_out "module broken cannot be read"
  assert_out "nothing to save"
  # A module run.sh would leave out: its own check (mcp_check) or a
  # malformed server line, shown in the menu and when it is turned on.
  rm "$CFG/mcp.local/broken/mcp.sh"
  mkdir -p "$CFG/mcp.local/odd"
  printf 'MCP_CONFIG=(ODD_PORT)\nMCP_URL=https://odd.example/mcp\nmcp_check() { [[ "${ODD_PORT:-1}" == 1 ]] || echo "ODD_PORT must be 1"; }\n' > "$CFG/mcp.local/odd/mcp.sh"
  local odd; odd="$(setup_entry odd)"
  setup_run "$odd\n2\nq\ny\n"
  assert_out "note: agentbox leaves odd out of the start until this is fixed: ODD_PORT must be 1"
  assert_out "NOT USABLE: ODD_PORT must be 1"
  printf 'MCP_SERVERS=("a|https://odd.example/1|caller|A")\n' > "$CFG/mcp.local/odd/mcp.sh"
  setup_run "q\n"
  assert_out "NOT USABLE: its server 'a' is marked caller"
  rm -r "$CFG/mcp.local/odd"
  # No config.env and the directory not writable: nothing left behind.
  rm "$CFG/config.env"*
  chmod a-w "$CFG"
  setup_run "$services\nredis\ns\nq\ny\n"
  chmod u+w "$CFG"
  assert_out "could not write"
  [[ -e "$CFG/config.env" ]] && fail "config.env left by a failed save"
  return 0
}

# --- run.sh: other parts ---

test_sidecar_recreated_when_its_setup_changes() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=graylog" "GRAYLOG_URL=https://graylog.example"
  secrets graylog_basic
  ab_run --
  ab_run --
  run_line ab-mcp-graylog && fail "recreated without a change"
  # An unchanged sidecar costs one inspect of the container (and one of its
  # image), not one per field.
  assert_eq "$(grep -c '^podman inspect .* ab-mcp-graylog$' "$STUB_DIR/calls")" 1 "inspects of an unchanged sidecar"
  # A changed setting reaches the sidecar only through a new container.
  : > "$CFG/config.env"; config "AB_MCP=graylog" "GRAYLOG_URL=https://graylog2.example"
  ab_run --
  run_line ab-mcp-graylog | grep -q 'GRAYLOG_URL=https://graylog2.example' || fail "not recreated after its setting changed"
  # So does a changed file it mounts, such as its nginx template.
  ab_run --
  run_line ab-mcp-graylog && fail "recreated without a change"
  echo "# changed" >> "$AB/mcp/graylog/nginx.conf.template"
  ab_run --
  run_line ab-mcp-graylog >/dev/null || fail "not recreated after its template changed"
  run_line ab-egress && fail "squid recreated although nothing of it changed"
}

# A rebuilt or pulled image keeps its tag: the sidecar follows the image.
test_sidecar_recreated_on_new_image() {
  setup "${FUNCNAME[0]}"
  ab_run --
  ab_run --
  run_line ab-egress && fail "recreated without a change"
  echo "localhost/agentbox-squid rebuilt-squid" >> "$STUB_DIR/image_ids"
  ab_run --
  run_line ab-egress | grep -q ' localhost/agentbox-squid$' || fail "squid not recreated on its new image"
  return 0
}

test_mcp_graylog_checks_caller_token() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=graylog" "GRAYLOG_URL=https://graylog.example"
  secrets graylog_basic
  ab_run --
  assert_rc 0
  assert_out "created secret graylog_mcp_caller"
  run_line ab-mcp-graylog | grep -q -- '--secret graylog_mcp_caller,type=env,target=GRAYLOG_CALLER_TOKEN' || fail "token not given to the sidecar"
  assert_file_has "$(cache mcp-claude.json)" '"Bearer \$\{AB_MCP_TOKEN_GRAYLOG\}"'
  assert_file_has "$ROOT/mcp/graylog/nginx.conf.template" 'http_authorization != "Bearer \$\{GRAYLOG_CALLER_TOKEN\}"'
}

test_build_args_from_config() {
  setup "${FUNCNAME[0]}"
  config "AB_PYTHON_VERSIONS=3.11 3.13" "AB_GOLANGCI_LINT_VERSION=" "AB_GRAPHIFY_EXTRAS=[terraform]"
  ab_run AB_UPGRADE=1 --
  assert_rc 0
  local b; b="$(grep '^podman build .*--pull' "$STUB_DIR/calls")"
  [[ "$b" == *"--build-arg GRAPHIFY_EXTRAS=[terraform] "* ]] || fail "graphify extras: $b"
  [[ "$b" == *"--build-arg PYTHON_VERSIONS=3.11 3.13 "* ]] || fail "python versions: $b"
  [[ "$b" == *"--build-arg GOLANGCI_LINT_VERSION= "* ]] || fail "empty golangci-lint version not passed: $b"
  [[ "$b" == *GO_VERSION=* ]] && fail "unset Go version passed: $b"
  # Built from an empty, temporary context, never the agentbox directory.
  local ctx="${b##* }"
  [[ "$ctx" == "$AB" || "$ctx" == "$AB/" ]] && fail "build context is the agentbox directory"
  [[ -e "$ctx" ]] && fail "build context $ctx left behind"
  [[ "$b" == *"--layers=false"* ]] || fail "intermediate layers kept: $b"
}

test_replaced_images_removed() {
  setup "${FUNCNAME[0]}"
  ab_run --
  grep -q '^podman rmi' "$STUB_DIR/calls" && fail "removed an image without an upgrade"
  # An upgrade replaces the agentbox image and squid's; nginx stays the same.
  # An open session still uses the old agentbox image: podman refuses.
  ab_run AB_UPGRADE=1 STUB_BUILT_ID=img-2 STUB_PULL_NEW="docker.io/library/nginx:alpine" STUB_RMI_FAIL=img-1 --
  assert_rc 0
  grep -qx 'podman rmi id-docker.io/library/nginx:alpine' "$STUB_DIR/calls" || fail "old nginx image not removed"
  grep -qx 'podman rmi img-1' "$STUB_DIR/calls" || fail "old agentbox image not tried"
  assert_eq "$(cat "$(cache retired-images)")" "localhost/agentbox img-1" "kept for later"
  # The next start, with the session gone, removes it.
  ab_run --
  grep -qx 'podman rmi img-1' "$STUB_DIR/calls" || fail "old agentbox image not removed later"
  assert_eq "$(cat "$(cache retired-images)")" "" "list after removal"
}

test_disabled_sidecars_removed() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana graylog" "GRAFANA_URL=https://g.example" "GRAYLOG_URL=https://l.example"
  secrets grafana_sa graylog_basic openai_api_key
  ab_run --
  assert_eq "$(started)" "ab-egress ab-llm-openai ab-mcp-grafana ab-mcp-graylog" "sidecars"
  echo "redis docker.io/library/redis:7" >> "$STUB_DIR/running"
  : > "$CFG/config.env"; config "AB_MCP=grafana" "GRAFANA_URL=https://g.example"
  grep -vx openai_api_key "$STUB_DIR/secrets" > "$STUB_DIR/secrets.new"; mv "$STUB_DIR/secrets.new" "$STUB_DIR/secrets"
  ab_run --
  assert_rc 0
  assert_eq "$(started)" "ab-egress ab-mcp-grafana redis" "after disabling graylog and the OpenAI key"
  assert_out "removed ab-mcp-graylog, no longer enabled"
  grep -qx 'podman rm -f -v ab-mcp-graylog' "$STUB_DIR/calls" || fail "anonymous volumes not removed"
}

test_sidecars_mount_copies_not_repo_files() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=graylog github" "GRAYLOG_URL=https://graylog.example"
  secrets graylog_basic github_pat openai_api_key
  ab_run --
  assert_rc 0
  # No sidecar may mount a file of agentbox itself: ":Z" would make it
  # private to the sidecar and unreadable for sessions and git.
  grep '^podman run -d' "$STUB_DIR/calls" | tr ' ' '\n' | grep -E "^$AB/.*:Z$" \
    && fail "a sidecar mounts a repo file with :Z"
  local c
  for c in ab-egress ab-mcp-graylog ab-mcp-github ab-llm-openai; do
    grep "^podman run -d --replace --name $c " "$STUB_DIR/calls" | grep -q "$T/home/.cache/agentbox/sidecars/$c/" \
      || fail "$c does not mount its copy"
  done
}

test_egress_recreated_when_squid_conf_changes() {
  setup "${FUNCNAME[0]}"
  ab_run --
  ab_run --
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" && fail "recreated without a change"
  echo "acl allowed dstdomain example.org" >> "$AB/squid.conf"
  ab_run --
  grep -q '^podman run -d --replace --name ab-egress' "$STUB_DIR/calls" || fail "not recreated after squid.conf changed"
}

# --- run.sh: session ---

test_session_basics() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/env" "$AB/agents"
  echo "DB=x" > "$CFG/env/repo.env"
  echo "# rules" > "$CFG/AGENTS.md"
  ab_run --
  assert_rc 0
  assert_eq "$(head -n1 "$T/out")" "agentbox dev ($(realpath "$AB"))" "banner from a clone"
  local args; args="$(session_args)"
  grep -qx -- "$REPO:/work/repo:z" <<<"$args" || fail "repo not mounted at /work/repo"
  grep -qx -- "$REPO/.git/hooks:/work/repo/.git/hooks:ro,z" <<<"$args" || fail ".git/hooks not read-only"
  grep -qx -- "$REPO/.git/config:/work/repo/.git/config:ro,z" <<<"$args" || fail ".git/config not read-only"
  grep -qx -- "$CFG/env/repo.env" <<<"$args" || fail "env file not passed"
  grep -qx -- "$CFG/AGENTS.md:/home/node/.claude/CLAUDE.md:ro,z" <<<"$args" || fail "AGENTS.md not mounted"
  grep -qx -- '--cap-drop=ALL' <<<"$args" || fail "capabilities not dropped"
  grep -A1 -x -- '--dns' <<<"$args" | grep -qx '127.0.0.1' || fail "external DNS not cut off"
}

test_shell_mode() {
  setup "${FUNCNAME[0]}"
  : > "$STUB_DIR/secrets"   # no claude_oauth: not needed without an agent
  config "AB_MCP=grafana" "GRAFANA_URL=https://g.example"
  secrets grafana_sa
  ab_run AB_AGENT=shell -- tests/escape.sh
  assert_rc 0
  grep -q 'npm' "$STUB_DIR/calls" && fail "an agent was installed"
  grep -qE '^podman run --rm -i .* --entrypoint /bin/bash .* localhost/agentbox tests/escape.sh$' "$STUB_DIR/calls" \
    || fail "session command: $(grep -o 'localhost/agentbox.*' "$STUB_DIR/calls" | tail -1)"
  local args; args="$(session_args)"
  grep -qx 'ab-shell-home:/home/node' <<<"$args" || fail "not its own home volume"
  grep -q '^/opt/' <<<"$args" && fail "an agent tools volume is mounted"
  grep -qx -- "$(cache mcp-claude.json):/etc/agentbox/mcp.json:ro,z" <<<"$args" || fail "MCP config not mounted"
  grep -qx 'grafana_mcp_caller,type=env,target=AB_MCP_TOKEN_GRAFANA' <<<"$args" || fail "caller token not passed"
  assert_eq "$(grep -c '^ab-shell-home' <<<"$args")" 1 "home mounts"
}

test_refuses_agentbox_code_and_user_files() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$T/elsewhere/env"
  local r
  # The code, a directory containing it, your files, the env dir set
  # elsewhere and a directory inside it, a directory containing them all.
  for r in "$AB" "$T" "$CFG" "$T/elsewhere" "$T/elsewhere/env" "$T/home"; do
    : > "$STUB_DIR/calls"
    env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_CHECK_UPDATES=0 \
        AB_ENV_DIR="$T/elsewhere/env" bash "$AB/run.sh" "$r" > "$T/out" 2>&1 < /dev/null
    RC=$?
    assert_rc 2
    assert_out "refusing to mount $r: it overlaps"
    grep -q '^podman run' "$STUB_DIR/calls" && fail "$r: something started"
  done
  # Another installed version (rollback would run it), and the directory of
  # git-guard (it runs on every git call on the host).
  # The sidecars' copies in the cache, which may hold passwords (mcp/dbhub).
  mkdir -p "$T/home/.local/share/agentbox/versions/v9.9.9" "$T/home/.local/bin" "$T/home/.cache/agentbox/sidecars"
  for r in "$T/home/.local/share/agentbox/versions/v9.9.9" "$T/home/.local/bin" "$T/home/.cache"; do
    ab_run_repo "$r"
    assert_rc 2
    assert_out "refusing to mount $r: it overlaps"
  done
  # A separate clone of agentbox is an ordinary repo.
  cp -R "$AB" "$T/clone"
  REPO="$T/clone"
  ab_run --
  assert_rc 0
}

test_user_files_in_old_place_stop_the_start() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$AB/env" "$AB/agents" "$AB/pi/extensions" "$CFG/skills" "$AB/skills/mine"
  echo "DB=x" > "$AB/env/repo.env"
  echo "# rules" > "$AB/agents/AGENTS.md"
  rm "$CFG/config.env"
  echo "AB_SERVICES=" > "$AB/config.env"
  ab_run --
  assert_rc 2
  assert_out "your files belong in $CFG"
  assert_out "mv '$AB/env' '$CFG/env'"
  assert_out "mv '$AB/agents/AGENTS.md' '$CFG/AGENTS.md'"
  assert_out "mv '$AB/config.env' '$CFG/config.env'"
  assert_out "both exist: merge $AB/skills into $CFG/skills by hand"
  grep -q '^podman' "$STUB_DIR/calls" && fail "podman called before the check"
  [[ -e "$AB/pi/extensions" ]] && fail "empty old pi/extensions left"
  # Once moved, the start goes ahead with the new place.
  mv "$AB/env" "$CFG/env"; mv "$AB/agents/AGENTS.md" "$CFG/AGENTS.md"; mv "$AB/config.env" "$CFG/config.env"
  rm -r "$AB/skills"
  ab_run --
  assert_rc 0
  assert_no_out "belong in"
  session_args | grep -qx -- "$CFG/env/repo.env" || fail "new env file not used"
}

test_missing_agent_secret() {
  setup "${FUNCNAME[0]}"
  : > "$STUB_DIR/secrets"
  ab_run --
  assert_rc 1
  assert_out "missing podman secrets: claude_oauth"
}

test_graphify_skill_installed_and_refreshed() {
  setup "${FUNCNAME[0]}"
  ab_run STUB_GRAPHIFY=ok --
  assert_rc 0
  [[ -f "$CFG/skills/graphify/SKILL.md" ]] || fail "claude variant not installed"
  [[ -f "$T/home/.cache/agentbox/graphify-pi/graphify/SKILL.md" ]] || fail "pi variant not installed"
  assert_eq "$(cat "$CFG/skills/graphify/.agentbox-image" 2>/dev/null)" "img-1" "stamp"
  ab_run STUB_GRAPHIFY=ok --
  grep -q 'graphify install' "$STUB_DIR/calls" && fail "reinstalled for the same image"
  ab_run STUB_GRAPHIFY=ok STUB_IMAGE_ID=img-2 --
  grep -q 'graphify install' "$STUB_DIR/calls" || fail "not reinstalled for a new image"
}

test_graphify_failure_does_not_stop_session() {
  setup "${FUNCNAME[0]}"
  ab_run STUB_GRAPHIFY=fail --
  assert_rc 0
  assert_out "could not extract the graphify skill"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "session did not start"
}

test_graphify_foreign_skill_left_alone() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/skills/graphify"
  echo mine > "$CFG/skills/graphify/SKILL.md"
  ab_run STUB_GRAPHIFY=ok --
  assert_rc 0
  assert_out "was not installed by agentbox"
  assert_eq "$(cat "$CFG/skills/graphify/SKILL.md")" "mine"
}


test_skills_state_migrated_from_vendor() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$AB/vendor/graphify/pi/graphify" "$CFG/skills/acme-tdd"
  printf '%s\n' "URL=https://github.com/acme/skills" "COMMIT=$(printf 'a%.0s' {1..40})" "SKILLS_ONLY=tdd" \
    "SKILLS_PREFIX=acme" "AB_SKILLS_DIR=$CFG/skills" > "$AB/vendor/acme__skills.sync"
  printf 'acme-tdd\n' > "$CFG/skills/.vendored-acme__skills"
  ab_run --
  assert_rc 0
  assert_out "moved the record of acme__skills"
  local st="$CFG/skills/.sources/acme__skills"
  assert_file_has "$st" '^URL=https://github.com/acme/skills$'
  assert_file_has "$st" '^SKILL=acme-tdd$'
  assert_file_lacks "$st" 'AB_SKILLS_DIR'
  [[ -e "$AB/vendor" ]] && fail "vendor/ left behind"
  [[ -e "$CFG/skills/.vendored-acme__skills" ]] && fail "old manifest left behind"
  [[ -d "$CFG/skills/acme-tdd" ]] || fail "installed skill touched"
}

# --- check-updates.sh -------------------------------------------------------

# Fake curl: registry answers with the digest in $T/remote_digest (or fails
# when it is "fail"); fake git ls-remote answers with $T/remote_head.
cu_setup() {
  setup "$1"
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo curl >> "$T/net"
echo "\${*: -1}" >> "$T/urls"
d="\$(cat "$T/remote_digest" 2>/dev/null)"
[[ "\$d" == fail ]] && exit 7
printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n' "\$d"
EOF
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == ls-remote ]]; then
  echo git >> "$T/net"
  h="\$(cat "$T/remote_head" 2>/dev/null)"; [[ -n "\$h" ]] || exit 1
  printf '%s\tHEAD\n' "\$h"; exit 0
fi
exec "$(command -v git)" "\$@"
EOF
  chmod +x "$T/bin/curl" "$T/bin/git"
  echo "ab-mcp-grafana docker.io/grafana/mcp-grafana:latest" > "$STUB_DIR/running"
  echo "my-redis docker.io/library/redis:7" >> "$STUB_DIR/running"
  echo "docker.io/grafana/mcp-grafana:latest sha256:aaa" > "$STUB_DIR/digests"
  echo aaa > "$T/remote_digest"
  mkdir -p "$CFG/skills/.sources"
}

cu_run() {  # [args...]
  : > "$T/net"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" \
      bash "$AB/check-updates.sh" "$@" > "$T/out" 2>&1 < /dev/null
  RC=$?
}
net_calls() { wc -l < "$T/net" | tr -d ' '; }

test_updates_all_current_sets_stamp() {
  cu_setup "${FUNCNAME[0]}"
  cu_run --if-due
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "output"
  [[ -f "$T/home/.cache/agentbox.updates.checked" ]] || fail "stamp not set"
  cu_run --if-due
  assert_eq "$(net_calls)" 0 "network calls within the interval"
  cu_run
  [[ "$(net_calls)" -gt 0 ]] || fail "a manual run must check"
}

test_updates_new_image_reported() {
  cu_setup "${FUNCNAME[0]}"
  echo bbb > "$T/remote_digest"
  cu_run --if-due
  assert_out "update available: image docker.io/grafana/mcp-grafana:latest"
  assert_no_out "redis"
  assert_out "run .*check-updates.sh in a terminal"
  [[ -f "$T/home/.cache/agentbox.updates.checked" ]] && fail "stamp set although an update is pending"
}

test_updates_stale_container_reported() {
  cu_setup "${FUNCNAME[0]}"
  echo "ab-mcp-grafana old-id" > "$STUB_DIR/container_images"
  cu_run
  assert_out "container ab-mcp-grafana runs an older image"
}

test_updates_registry_down_warns() {
  cu_setup "${FUNCNAME[0]}"
  echo fail > "$T/remote_digest"
  cu_run --if-due
  assert_rc 0
  assert_out "could not check docker.io/grafana/mcp-grafana:latest"
  [[ -f "$T/home/.cache/agentbox.updates.checked" ]] && fail "stamp set after a failed check"
  # Run by run.sh: not in the start's list (warnings_review), which would
  # ask at every start while offline...
  : > "$T/warnings"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_WARNINGS_TO="$T/warnings" \
      bash "$AB/check-updates.sh" --if-due > "$T/out" 2>&1 < /dev/null
  assert_out "could not check docker.io/grafana/mcp-grafana:latest"
  [[ -s "$T/warnings" ]] && fail "a failed check asks before the session: $(cat "$T/warnings")"
}

# A failed update is in the start's list (warnings_review): answered at a
# terminal, the pull fails.
test_updates_failed_pull_in_warnings() {
  command -v script >/dev/null || return 0
  cu_setup "${FUNCNAME[0]}"
  echo bbb > "$T/remote_digest"
  : > "$T/warnings"
  printf 'y\n' | timeout 60 script -qec "$(printf '%q ' env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" \
      PATH="$T/bin:$PATH" STUB_DIR="$STUB_DIR" STUB_PULL_FAIL=1 AB_WARNINGS_TO="$T/warnings" \
      bash "$AB/check-updates.sh")" /dev/null > "$T/out" 2>&1
  assert_out "pull of docker.io/grafana/mcp-grafana:latest failed"
  grep -q "pull of docker.io/grafana/mcp-grafana:latest failed" "$T/warnings" \
    || fail "a failed pull not in the start's list: $(cat "$T/warnings")"
  # run.sh passes its list on.
  config "AB_MCP=grafana" "GRAFANA_URL=https://g.example"
  secrets grafana_sa
  printf '%s\n' '#!/usr/bin/env bash' 'echo "AB_WARNINGS_TO=${AB_WARNINGS_TO:-}" > "'"$T"'/cu-env"' > "$AB/check-updates.sh"
  ab_run AB_CHECK_UPDATES=1 --
  grep -q '^AB_WARNINGS_TO=/' "$T/cu-env" || fail "run.sh does not pass its warnings file: $(cat "$T/cu-env" 2>/dev/null)"
}

test_updates_skills_behind() {
  cu_setup "${FUNCNAME[0]}"
  printf '%s\n' "URL=https://github.com/acme/skills" "COMMIT=$(printf 'a%.0s' {1..40})" \
    "SKILLS_ONLY=tdd" "SKILLS_PREFIX=acme" "AB_SKILLS_DIR=" > "$CFG/skills/.sources/acme__skills"
  printf 'b%.0s' {1..40} > "$T/remote_head"
  cu_run
  assert_out "update available: skills from acme__skills, aaaaaaa -> bbbbbbb"
  assert_out "github.com/acme/skills/compare/aaaaaaa...bbbbbbb"
}

test_updates_rejects_bad_sync_file() {
  cu_setup "${FUNCNAME[0]}"
  printf '%s\n' "URL=ext::sh -c id" "COMMIT=abc" > "$CFG/skills/.sources/evil"
  cu_run
  assert_out "evil: bad URL or COMMIT, skipped"
  assert_eq "$(grep -c git "$T/net")" 0 "git calls for a bad record"
}

# --- sync-skills.sh ---------------------------------------------------------

# A local "remote" repository at $T/src/acme/skills with skills in nested
# directories, one of them referring to another.
ss_setup() {
  setup "$1"
  local src="$T/src/acme/skills"
  mkdir -p "$src/eng/review" "$src/eng/tdd" "$src/misc/notes"
  printf -- '---\nname: review\ndescription: Review.\n---\n\nCall the Skill tool with "tdd".\n' > "$src/eng/review/SKILL.md"
  printf -- '---\nname: tdd\ndescription: TDD.\n---\n\nRed, green.\n' > "$src/eng/tdd/SKILL.md"
  printf -- '---\nname: notes\ndescription: Notes.\n---\n' > "$src/misc/notes/SKILL.md"
  git -C "$src" init -q -b main
  git -C "$src" -c user.name=t -c user.email=t@t add -A
  git -C "$src" -c user.name=t -c user.email=t@t commit -q -m init
  SRC="$src"
}

ss_run() {  # [env...]
  env HOME="$T/home" "$@" bash "$AB/sync-skills.sh" "$SRC" > "$T/out" 2>&1 < /dev/null
  RC=$?
}

test_sync_prefix_and_note() {
  ss_setup "${FUNCNAME[0]}"
  ss_run SKILLS_ONLY=review,tdd
  assert_rc 0
  assert_eq "$(ls "$CFG/skills" | paste -sd' ' -)" "acme-review acme-tdd"
  assert_file_has "$CFG/skills/acme-review/SKILL.md" '^name: acme-review$'
  assert_file_has "$CFG/skills/acme-review/SKILL.md" 'Installed with a prefix'
  assert_file_has "$CFG/skills/acme-review/SKILL.md" '\(`review`, `tdd`\)'
  # The skill's own text is not rewritten.
  assert_file_has "$CFG/skills/acme-review/SKILL.md" 'Skill tool with "tdd"'
  assert_file_has "$CFG/skills/.sources/acme__skills" '^SKILLS_ONLY=review,tdd$'
  assert_file_has "$CFG/skills/.sources/acme__skills" '^COMMIT=[0-9a-f]{40}$'
}

test_sync_deselect_and_prefix_change() {
  ss_setup "${FUNCNAME[0]}"
  ss_run SKILLS_ONLY=review,tdd
  ss_run SKILLS_ONLY=tdd SKILLS_PREFIX=x
  assert_rc 0
  assert_eq "$(ls "$CFG/skills" | paste -sd' ' -)" "x-tdd"
  ss_run SKILLS_ONLY=tdd SKILLS_PREFIX=
  assert_eq "$(ls "$CFG/skills" | paste -sd' ' -)" "tdd"
  assert_file_lacks "$CFG/skills/tdd/SKILL.md" 'Installed with a prefix'
}

test_sync_refuses_foreign_skill() {
  ss_setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/skills/acme-tdd"
  echo mine > "$CFG/skills/acme-tdd/SKILL.md"
  ss_run SKILLS_ONLY=tdd
  assert_rc 1
  assert_out "was not installed from acme__skills; not overwriting"
  assert_eq "$(cat "$CFG/skills/acme-tdd/SKILL.md")" "mine"
}

test_sync_subdir() {
  ss_setup "${FUNCNAME[0]}"
  # A copy of a skill for another agent: the same name twice.
  mkdir -p "$SRC/.other/skills/tdd" "$SRC/out"
  cp "$SRC/eng/tdd/SKILL.md" "$SRC/.other/skills/tdd/"
  ln -s ../.. "$SRC/out/up"
  git -C "$SRC" -c user.name=t -c user.email=t@t add -A
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m copies
  ss_run
  assert_rc 1
  assert_out "skill name 'tdd' appears twice"
  ss_run SKILLS_SUBDIR=eng
  assert_rc 0
  assert_eq "$(ls "$CFG/skills" | paste -sd' ' -)" "acme-review acme-tdd"
  assert_file_has "$CFG/skills/.sources/acme__skills" '^SKILLS_SUBDIR=eng$'
  local bad
  for bad in ../x /etc eng/../.. out/up; do
    ss_run SKILLS_SUBDIR="$bad"
    assert_rc 1
  done
  ss_run SKILLS_SUBDIR=/
  assert_rc 1
  assert_out "SKILLS_SUBDIR '/' must be a plain path"
  ss_run SKILLS_SUBDIR=nope
  assert_rc 1
  assert_out "has no directory 'nope'"
  # A symlink inside the clone works; "." is the whole repository.
  ln -s eng "$SRC/linked"
  git -C "$SRC" -c user.name=t -c user.email=t@t add -A
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m link
  ss_run SKILLS_SUBDIR=linked
  assert_rc 0
  assert_eq "$(ls "$CFG/skills" | paste -sd' ' -)" "acme-review acme-tdd"
  ss_run SKILLS_SUBDIR=.
  assert_rc 1
  assert_out "skill name 'tdd' appears twice"
}

test_sync_bad_prefix() {
  ss_setup "${FUNCNAME[0]}"
  ss_run SKILLS_PREFIX=Bad
  assert_rc 1
  assert_out "must be lowercase"
}


# --- pi extensions (AB_PI_EXTENSIONS, sync-pi-extension.sh) -----------------

# A local "remote" repository at $T/src/acme/pi-ext: a pi extension with a
# package.json manifest; with "deps", also a dependency and its lock file.
px_setup() {  # <test name> [deps]
  setup "$1"
  local src="$T/src/acme/pi-ext"
  mkdir -p "$src/src"
  echo 'export default function () {}' > "$src/src/index.ts"
  if [[ "${2:-}" == deps ]]; then
    printf '%s\n' '{ "name": "pi-ext", "dependencies": { "nanoid": "^5" }, "pi": { "extensions": ["./src/index.ts"] } }' > "$src/package.json"
    printf '%s\n' '{ "lockfileVersion": 3, "packages": { "": { "name": "pi-ext" },' \
      '"node_modules/nanoid": { "version": "5.1.6", "resolved": "https://registry.npmjs.org/nanoid/-/nanoid-5.1.6.tgz" } } }' \
      > "$src/package-lock.json"
    echo 'registry=https://evil.example/' > "$src/.npmrc"
  else
    printf '%s\n' '{ "name": "pi-ext", "pi": { "extensions": ["./src/index.ts"] } }' > "$src/package.json"
  fi
  git -C "$src" init -q -b main
  git -C "$src" -c user.name=t -c user.email=t@t add -A
  git -C "$src" -c user.name=t -c user.email=t@t commit -q -m init
  SRC="$src"
  # Fake npm: records its arguments and whether the repo's .npmrc is gone.
  printf '%s\n' '#!/usr/bin/env bash' \
    "{ echo \"npm \$*\"; [[ -e .npmrc ]] && echo 'npmrc present'; } >> '$T/npm-calls'" \
    'mkdir -p node_modules/nanoid && echo x > node_modules/nanoid/index.js' > "$T/bin/npm"
  chmod +x "$T/bin/npm"
}
px_run() {  # <args...>
  env HOME="$T/home" PATH="$T/bin:$PATH" bash "$AB/sync-pi-extension.sh" "$@" > "$T/out" 2>&1 < /dev/null
  RC=$?
}
px_dir() { echo "$CFG/pi-extensions/$1"; }
px_rec() { echo "$CFG/pi-extensions.sources/$1"; }

test_pi_extension_sync_installs_and_records() {
  px_setup "${FUNCNAME[0]}"
  px_run myext "$SRC"
  assert_rc 0
  [[ -f "$(px_dir myext)/src/index.ts" && -f "$(px_dir myext)/package.json" ]] || fail "extension not installed"
  [[ -e "$(px_dir myext)/.git" ]] && fail ".git installed"
  assert_file_has "$(px_rec myext)" "^URL=$SRC\$"
  assert_file_has "$(px_rec myext)" '^COMMIT=[0-9a-f]{40}$'
  assert_file_has "$(px_rec myext)" '^REF=$'
  [[ -e "$T/npm-calls" ]] && fail "npm run for an extension without dependencies"
  # The record is outside the directory that sessions mount.
  [[ -e "$CFG/pi-extensions/.sources" ]] && fail "record inside the mounted directory"
  # Stopped after the move, before the record: still its own, installed again.
  rm "$(px_rec myext)"
  px_run myext "$SRC"
  assert_rc 0
  [[ -f "$(px_rec myext)" ]] || fail "an extension without its record not installed again"
  # A copy under another name carries the mark of the first: not ours.
  cp -R "$(px_dir myext)" "$(px_dir mycopy)"
  px_run mycopy "$SRC"
  assert_rc 1
  assert_out "was not installed by agentbox"
  px_run --remove myext
  assert_rc 0
  [[ -e "$(px_dir myext)" || -e "$(px_rec myext)" ]] && fail "not removed"
  return 0
}

test_pi_extension_sync_dependencies() {
  px_setup "${FUNCNAME[0]}" deps
  px_run myext "$SRC"
  assert_rc 0
  assert_file_has "$T/npm-calls" '^npm ci --omit=dev --omit=peer --ignore-scripts --no-bin-links'
  assert_file_lacks "$T/npm-calls" 'npmrc present'
  [[ -f "$(px_dir myext)/node_modules/nanoid/index.js" ]] || fail "dependencies not installed"
  # A dependency from git: npm would run its scripts on the host. Refused.
  sed -i 's#https://registry.npmjs.org/nanoid/-/nanoid-5.1.6.tgz#git+https://evil.example/x.git\#abc#' "$SRC/package-lock.json"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -am "git dependency"
  : > "$T/npm-calls"
  px_run myext "$SRC"
  assert_rc 1
  assert_out "node_modules/nanoid is not from the npm registry: git\+https://evil.example"
  [[ -s "$T/npm-calls" ]] && fail "npm run for a lock file with a git dependency"
  # Dependencies without a lock file: refused, the installed one stays.
  git -C "$SRC" rm -q package-lock.json
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m "no lock"
  px_run myext "$SRC"
  assert_rc 1
  assert_out "has dependencies but no package-lock.json"
  [[ -f "$(px_dir myext)/package-lock.json" ]] || fail "the installed version was replaced by a failed sync"
}

test_pi_extension_sync_ref_branch_tag_commit() {
  px_setup "${FUNCNAME[0]}"
  local first; first="$(git -C "$SRC" rev-parse HEAD)"
  git -C "$SRC" tag v1
  git -C "$SRC" branch stable
  echo 'export const x = 2' > "$SRC/src/two.ts"
  git -C "$SRC" -c user.name=t -c user.email=t@t add -A
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m two
  local r
  for r in stable v1 "$first"; do
    px_run "x-$r" "$SRC" "$r"
    assert_rc 0
    [[ -e "$(px_dir "x-$r")/src/two.ts" ]] && fail "REF $r: the newer commit installed"
    assert_file_has "$(px_rec "x-$r")" "^COMMIT=$first\$"
  done
  # Installed again over itself: no copy nested inside.
  px_run x-stable "$SRC" stable
  assert_rc 0
  compgen -G "$(px_dir x-stable)/.pi-extension-*" >/dev/null && fail "stage nested in the extension"
  # An option for git is refused.
  px_run evil "--upload-pack=touch $T/pwned"
  assert_rc 1
  [[ -e "$T/pwned" ]] && fail "a URL ran as a git option"
  # A relative local path works.
  (cd "$(dirname "$SRC")" && env HOME="$T/home" PATH="$T/bin:$PATH" bash "$AB/sync-pi-extension.sh" rel ./pi-ext > "$T/out" 2>&1)
  [[ -f "$(px_dir rel)/src/index.ts" ]] || fail "a relative path did not work: $(cat "$T/out")"
  px_run evil "$SRC" "--orphan=x"
  assert_rc 1
  assert_out "must not start with '-'"
  return 0
}

test_pi_extension_sync_refusals() {
  px_setup "${FUNCNAME[0]}"
  # Not a pi extension.
  printf '%s\n' '{ "name": "x" }' > "$SRC/package.json"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -am "not one"
  px_run myext "$SRC"
  assert_rc 1
  assert_out "is not a pi extension"
  # A symlink.
  printf '%s\n' '{ "name": "x", "pi": { "extensions": ["./src/index.ts"] } }' > "$SRC/package.json"
  ln -s /etc/passwd "$SRC/src/leak"
  git -C "$SRC" -c user.name=t -c user.email=t@t add -A
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m link
  px_run myext "$SRC"
  assert_rc 1
  assert_out "contains symlinks"
  # A directory of yours with that name is not replaced.
  git -C "$SRC" rm -q src/leak
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -m unlink
  mkdir -p "$(px_dir mine)"; echo mine > "$(px_dir mine)/index.ts"
  px_run mine "$SRC"
  assert_rc 1
  assert_out "was not installed by agentbox"
  assert_eq "$(cat "$(px_dir mine)/index.ts")" mine "your extension"
  px_run --remove mine
  [[ -f "$(px_dir mine)/index.ts" ]] || fail "--remove took an extension without a record"
  # An empty dependencies object needs neither a lock file nor npm.
  printf '%s\n' '{ "name": "x", "dependencies": {}, "pi": { "extensions": ["./src/index.ts"] } }' > "$SRC/package.json"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -q -am "empty deps"
  rm -f "$T/bin/npm"
  px_run other "$SRC"
  assert_rc 0
  # No staging directory left next to the mounted one.
  compgen -G "$CFG/.pi-extension-*" >/dev/null && fail "staging directory left"
  return 0
}

test_pi_extension_sources_at_start() {
  px_setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/pi-extensions.local.d"
  printf '%s\n' "url = '$SRC'" > "$CFG/pi-extensions.local.d/myext.toml"
  mkdir -p "$(px_dir handmade)"; echo x > "$(px_dir handmade)/index.ts"
  config "AB_PI_EXTENSIONS=myext"
  # A start of Claude Code does not install them: only pi mounts them.
  ab_run --
  assert_rc 0
  [[ -e "$(px_dir myext)" ]] && fail "installed at a start of Claude Code"
  ab_run AB_AGENT=pi --
  assert_rc 0
  [[ -f "$(px_dir myext)/src/index.ts" ]] || fail "enabled source not installed at the start"
  # Unchanged: not installed again.
  ab_run AB_AGENT=pi --
  assert_no_out "installing pi extension"
  # A pin installs it again at that ref, recorded as the pin.
  local first; first="$(git -C "$SRC" rev-parse HEAD)"
  printf '%s\n' "url = '$SRC'" "ref = '$first'" > "$CFG/pi-extensions.local.d/myext.toml"
  ab_run AB_AGENT=pi --
  assert_out "installing pi extension 'myext'"
  assert_file_has "$(px_rec myext)" "^REF=$first\$"
  # Its directory gone: installed again.
  rm -rf "$(px_dir myext)"
  ab_run AB_AGENT=pi --
  [[ -f "$(px_dir myext)/src/index.ts" ]] || fail "a removed directory not installed again"
  # One that you installed with the script yourself.
  px_run byhand "$SRC"
  # Disabled: removed; one copied in by hand or installed by hand stays.
  sed -i '/^AB_PI_EXTENSIONS=/d' "$CFG/config.env"
  ab_run AB_AGENT=pi --
  assert_rc 0
  [[ -e "$(px_dir myext)" ]] && fail "disabled extension left"
  [[ -f "$(px_dir handmade)/index.ts" ]] || fail "an extension copied by hand removed"
  [[ -f "$(px_dir byhand)/src/index.ts" ]] || fail "an extension installed with the script by hand removed"
  # Its install stopped before the record, then disabled: the mark says that
  # the start installed it, so the start removes it.
  config "AB_PI_EXTENSIONS=myext"
  ab_run AB_AGENT=pi --
  rm "$(px_rec myext)"
  sed -i '/^AB_PI_EXTENSIONS=/d' "$CFG/config.env"
  ab_run AB_AGENT=pi --
  [[ -e "$(px_dir myext)" ]] && fail "a disabled extension without its record left"
  [[ -f "$(px_dir byhand)/src/index.ts" ]] || fail "an extension installed by hand removed"
  # needs_skills: a warning while that skill source is not enabled.
  printf '%s\n' "url = '$SRC'" "needs_skills = ['acme']" > "$CFG/pi-extensions.local.d/myext.toml"
  config "AB_PI_EXTENSIONS=myext"
  ab_run AB_AGENT=pi --
  assert_rc 0
  assert_out "pi extension 'myext' uses the skill source 'acme'"
  # A source of yours with another name for the same repository counts.
  mkdir -p "$CFG/skills.local.d"
  printf '%s\n' "url = '$T/nowhere/acme/skills'" > "$CFG/skills.local.d/acme.toml"
  printf '%s\n' "url = '$T/nowhere/acme/skills'" > "$CFG/skills.local.d/mine.toml"
  ab_run AB_AGENT=pi AB_SKILLS=mine AB_CHECK_UPDATES=0 --
  assert_no_out "uses the skill source 'acme'"
  # A comma list, and ".git" on one URL: the same repository.
  printf '%s\n' "url = '$T/nowhere/acme/skills.git'" > "$CFG/skills.local.d/mine.toml"
  printf '%s\n' "url = '$T/nowhere/other/skills'" > "$CFG/skills.local.d/other.toml"
  ab_run AB_AGENT=pi AB_SKILLS=other,mine AB_CHECK_UPDATES=0 --
  assert_rc 0
  assert_no_out "uses the skill source 'acme'"
  ab_run AB_AGENT=pi AB_SKILLS=other,acme AB_CHECK_UPDATES=0 --
  assert_rc 0
  assert_no_out "uses the skill source 'acme'"
  # Neither under its name nor by its repository: the message.
  ab_run AB_AGENT=pi AB_SKILLS=other AB_CHECK_UPDATES=0 --
  assert_out "uses the skill source 'acme'"
  rm "$CFG/skills.local.d/other.toml"
  rm "$CFG/skills.local.d/acme.toml" "$CFG/skills.local.d/mine.toml"
  sed -i '/^AB_PI_EXTENSIONS=/d' "$CFG/config.env"
  # An unknown source stops the start, like AB_SKILLS.
  config "AB_PI_EXTENSIONS=nope"
  ab_run AB_AGENT=pi --
  assert_out "no pi extension source 'nope'"
  # An unknown key and a missing url stop the start. The error names the line.
  sed -i '/^AB_PI_EXTENSIONS=/d' "$CFG/config.env"
  config "AB_PI_EXTENSIONS=myext"
  printf '%s\n' "url = '$SRC'" "reff = 'v1'" > "$CFG/pi-extensions.local.d/myext.toml"
  ab_run AB_AGENT=pi --
  assert_rc 2
  assert_out "pi-extensions.local.d/myext.toml:2: unknown key 'reff' \\(unknown-key\\)"
  printf '%s\n' "# no url" "ref = 'v1'" > "$CFG/pi-extensions.local.d/myext.toml"
  ab_run AB_AGENT=pi --
  assert_rc 2
  assert_out "pi-extensions.local.d/myext.toml:1: the key 'url' is missing \\(missing-key\\)"
  return 0
}

# A pi extension source of yours from v0.1.x that a start of v0.1.x
# installed. The start converts it, and installs nothing again: the values
# that it compares with the record stay the same.
test_convert_pi_extension_source() {
  px_setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/pi-extensions.local.d"
  local first; first="$(git -C "$SRC" rev-parse HEAD)"
  printf '%s\n' '# my extension' "URL=$SRC" "REF=$first" 'NEEDS_SKILLS=acme,other' > "$CFG/pi-extensions.local.d/myext.conf"
  # The install of v0.1.x, with the values that its run.sh gave.
  env HOME="$T/home" PATH="$T/bin:$PATH" AB_PI_EXTENSIONS_PIN="$first" AB_PI_EXTENSIONS_SOURCE=1 \
    bash "$AB/sync-pi-extension.sh" myext "$SRC" "$first" > /dev/null 2>&1
  config "AB_PI_EXTENSIONS=myext"
  ab_run AB_AGENT=pi --
  assert_rc 0
  assert_out "pi-extensions.local.d/myext.conf -> myext.toml"
  assert_out "pi extension 'myext' uses the skill source 'acme'"
  assert_out "pi extension 'myext' uses the skill source 'other'"
  assert_no_out "installing pi extension"
  assert_eq "$(cat "$CFG/pi-extensions.local.d/myext.toml")" "# my extension
url = \"$SRC\"
ref = \"$first\"
needs_skills = [\"acme\", \"other\"]"
  ab_run AB_AGENT=pi --
  assert_rc 0
  assert_no_out "installing pi extension|converted"
  [[ -f "$(px_dir myext)/src/index.ts" ]] || fail "the extension is gone"
  # An old file of yours that cannot be converted (no URL) stops the start.
  # The start does not use the shared source of the same name in its place.
  printf '%s\n' 'REF=v1' > "$CFG/pi-extensions.local.d/ponytail.conf"
  # A local shared source: no network if the start uses it by mistake.
  printf '%s\n' "url = '$SRC'" > "$AB/pi-extensions.d/ponytail.toml"
  printf '%s\n' "AB_PI_EXTENSIONS=ponytail" > "$CFG/config.env"
  ab_run AB_AGENT=pi --
  assert_rc 2
  assert_out "ponytail.conf was not converted to TOML .*does not use the shared pi extension source"
  [[ -e "$(px_dir ponytail)" ]] && fail "the shared source was installed in place of yours"
  return 0
}

test_pi_extension_shared_sources_and_setup() {
  setup "${FUNCNAME[0]}"
  cp "$ROOT/agentbox" "$ROOT/config.env.example" "$AB/"
  local n
  for n in pi-subagents pi-prompt-history; do
    assert_file_has "$AB/pi-extensions.d/$n.toml" '^url = "https://github.com/'
  done
  echo "AB_MCP=" > "$CFG/config.env"
  # Setup shows the URL of each pi extension source. An old file of yours
  # that is not converted shows a note.
  mkdir -p "$CFG/pi-extensions.local.d"
  echo "url = 'https://example.com/me/ext'" > "$CFG/pi-extensions.local.d/mine.toml"
  echo "REF=v1" > "$CFG/pi-extensions.local.d/broken.conf"
  setup_run "q\n"
  assert_out '\[ \] pi-prompt-history +https://github.com/Integralist/pi-prompt-history$'
  assert_out '\[ \] mine +\(yours\) https://example.com/me/ext$'
  assert_out '\[ \] broken +\(yours\) \(not converted, see the warning above\)$'
  rm "$CFG/pi-extensions.local.d/broken.conf"
  local sub; sub="$(setup_entry pi-subagents)"
  [[ -n "$sub" ]] || fail "pi-subagents not in the setup menu"
  setup_run "$sub\ns\n"
  assert_out "pi extensions \(AB_PI_EXTENSIONS"
  grep -qx 'AB_PI_EXTENSIONS=pi-subagents' "$CFG/config.env" || fail "not saved: $(grep AB_PI_EXTENSIONS "$CFG/config.env")"
}

test_updates_pi_extension_behind() {
  cu_setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/pi-extensions.sources"
  printf '%s\n' "URL=https://github.com/acme/pi-ext" "COMMIT=$(printf 'a%.0s' {1..40})" "REF=" > "$CFG/pi-extensions.sources/myext"
  printf 'b%.0s' {1..40} > "$T/remote_head"
  cu_run
  assert_out "update available: pi extension myext, aaaaaaa -> bbbbbbb"
  assert_out "github.com/acme/pi-ext/compare/aaaaaaa...bbbbbbb"
  # Pinned: not checked. A bad record: skipped.
  sed -i 's/^REF=$/REF=v1/' "$CFG/pi-extensions.sources/myext"
  printf '%s\n' "URL=ext::sh -c id" "COMMIT=abc" > "$CFG/pi-extensions.sources/evil"
  cu_run
  assert_no_out "pi extension myext"
  assert_out "evil: bad URL or COMMIT, skipped"
  # A pi extension record without a URL: a warning (a skill record from
  # before URLs were recorded is skipped quietly).
  printf '%s\n' "COMMIT=$(printf 'a%.0s' {1..40})" "REF=" > "$CFG/pi-extensions.sources/nourl"
  cu_run
  assert_out "nourl: bad URL or COMMIT, skipped"
  rm "$CFG/pi-extensions.sources/nourl"
  # An ssh URL: no check, and no warning for the list before the session.
  rm "$CFG/pi-extensions.sources/evil"
  printf '%s\n' "URL=git@github.com:acme/pi-ext.git" "COMMIT=$(printf 'a%.0s' {1..40})" "REF=" > "$CFG/pi-extensions.sources/myext"
  : > "$T/warnings"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_WARNINGS_TO="$T/warnings" \
      bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_out "pi extension myext: updates are checked only for an https:// URL"
  [[ -s "$T/warnings" ]] && fail "an ssh URL warns before each session: $(cat "$T/warnings")"
  # A start of Claude Code: no offer (only a start of pi installs them).
  printf '%s\n' "URL=https://github.com/acme/pi-ext" "COMMIT=$(printf 'a%.0s' {1..40})" "REF=" > "$CFG/pi-extensions.sources/myext"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_CHECK_AGENT=claude \
      bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_no_out "pi extension myext"
  # Run by hand: the enabled list comes from config.env.
  printf '%s\n' "URL=https://github.com/acme/pi-ext" "COMMIT=$(printf 'a%.0s' {1..40})" "REF=" "SOURCE=1" > "$CFG/pi-extensions.sources/myext"
  config "AB_PI_EXTENSIONS=other"
  cu_run
  assert_no_out "pi extension myext"
  sed -i '/^AB_PI_EXTENSIONS=/d' "$CFG/config.env"
  # Disabled (run.sh passes the enabled list): no offer.
  printf '%s\n' "URL=https://github.com/acme/pi-ext" "COMMIT=$(printf 'a%.0s' {1..40})" "REF=" "SOURCE=1" > "$CFG/pi-extensions.sources/myext"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_PI_EXTENSIONS_ENABLED=" other " \
      bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_no_out "pi extension myext"
  env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" PATH="$T/bin:$PATH" AB_PI_EXTENSIONS_ENABLED=" myext " \
      bash "$AB/check-updates.sh" > "$T/out" 2>&1 < /dev/null
  assert_out "update available: pi extension myext"
}

# --- run.sh: skill sources (AB_SKILLS) --------------------------------------

src_conf() {  # <dir: skills.d|skills.local.d> <name> <TOML lines...>
  local dir name="$2"
  if [[ "$1" == skills.d ]]; then dir="$AB/$1"; else dir="$CFG/$1"; fi
  shift 2
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/$name.toml"
}
installed() { ls "$CFG/skills" 2>/dev/null | grep -v '^graphify$' | paste -sd' ' -; }

test_skills_source_subdir() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "url = '$SRC'" "subdir = 'misc'" "prefix = ''"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 0
  assert_eq "$(installed)" "notes"
  # A changed subdir syncs again.
  src_conf skills.d acme "url = '$SRC'" "subdir = 'eng'" "prefix = ''"
  ab_run --
  assert_eq "$(installed)" "review tdd"
  # Trailing slashes are the same subdir: no new sync.
  src_conf skills.d acme "url = '$SRC'" "subdir = 'eng//'" "prefix = ''"
  ab_run --
  assert_no_out "syncing skills from 'acme'"
  # The shared source: skills/ only, no prefix.
  assert_file_has "$AB/skills.d/ponytail.toml" '^subdir = "skills"$'
  assert_file_has "$AB/skills.d/ponytail.toml" '^prefix = ""$'
  assert_file_has "$AB/pi-extensions.d/ponytail.toml" '^url = "https://github.com/DietrichGebert/ponytail"$'
  assert_file_has "$AB/pi-extensions.d/ponytail.toml" '^needs_skills = \["ponytail"\]$'
}

test_skills_source_installed_once() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "url = '$SRC'" "only = ['tdd', 'review']"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 0
  assert_out "syncing skills from 'acme'"
  assert_eq "$(installed)" "acme-review acme-tdd"
  assert_file_has "$CFG/skills/.sources/acme__skills" '^SOURCE=acme$'
  ab_run --
  assert_no_out "syncing skills"
}

test_skills_source_selection_change_keeps_version() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "url = '$SRC'" "only = ['tdd']"
  config "AB_SKILLS=acme"
  ab_run --
  local before; before="$(source_value "$CFG/skills/.sources/acme__skills" COMMIT)"
  printf -- '---\nname: tdd\n---\nNewer.\n' > "$SRC/eng/tdd/SKILL.md"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -qam newer
  src_conf skills.d acme "url = '$SRC'" "only = ['tdd', 'notes']"
  ab_run --
  assert_rc 0
  assert_eq "$(installed)" "acme-notes acme-tdd"
  assert_eq "$(source_value "$CFG/skills/.sources/acme__skills" COMMIT)" "$before" "installed commit"
  assert_file_lacks "$CFG/skills/acme-tdd/SKILL.md" 'Newer'
  assert_eq "$(source_value "$CFG/skills/.sources/acme__skills" REF)" "" "REF (must not look pinned)"
}

test_skills_source_disabled_removed_manual_kept() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "url = '$SRC'" "only = ['tdd']"
  config "AB_SKILLS=acme"
  ab_run --
  # A repository synced by hand, without a source, stays.
  local other="$T/src/other/kit"
  mkdir -p "$other/x"
  printf -- '---\nname: x\n---\n' > "$other/x/SKILL.md"
  git -C "$other" init -q -b main
  git -C "$other" -c user.name=t -c user.email=t@t add -A
  git -C "$other" -c user.name=t -c user.email=t@t commit -qm init
  env HOME="$T/home" bash "$AB/sync-skills.sh" "$other" > /dev/null 2>&1
  : > "$CFG/config.env"
  ab_run --
  assert_rc 0
  assert_out "removing skills of disabled source 'acme'"
  assert_eq "$(installed)" "other-x"
  [[ -f "$CFG/skills/.sources/acme__skills" ]] && fail "record of the disabled source kept"
}

test_skills_source_pinned() {
  ss_setup "${FUNCNAME[0]}"
  local first; first="$(git -C "$SRC" rev-parse HEAD)"
  printf -- '---\nname: tdd\n---\nNewer.\n' > "$SRC/eng/tdd/SKILL.md"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -qam newer
  src_conf skills.d acme "url = '$SRC'" "only = ['tdd']" "ref = '$first'"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 0
  assert_file_lacks "$CFG/skills/acme-tdd/SKILL.md" 'Newer'
  assert_eq "$(source_value "$CFG/skills/.sources/acme__skills" REF)" "$first" "REF"
  ab_run --
  assert_no_out "syncing skills"
}

test_skills_source_local_overrides_and_prefix() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "url = '$SRC'" "only = ['tdd']"
  src_conf skills.local.d acme "url = '$SRC'" "only = ['review']" "prefix = ''"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 0
  assert_eq "$(installed)" "review"
}

test_skills_source_errors() {
  ss_setup "${FUNCNAME[0]}"
  config "AB_SKILLS=nope"
  ab_run --
  assert_rc 2
  assert_out "no skill source 'nope'"
  : > "$CFG/config.env"; config "AB_SKILLS=../x"
  ab_run --
  assert_rc 2
  assert_out "invalid source name"
  # An unknown key and a missing or empty url: errors with the line.
  : > "$CFG/config.env"; config "AB_SKILLS=acme"
  src_conf skills.local.d acme "url = '$SRC'" "subdirr = 'eng'"
  ab_run --
  assert_rc 2
  assert_out "skills.local.d/acme.toml:2: unknown key 'subdirr' \(unknown-key\)"
  src_conf skills.local.d acme "# no url" "only = ['tdd']"
  ab_run --
  assert_rc 2
  assert_out "skills.local.d/acme.toml:1: the key 'url' is missing \(missing-key\)"
  src_conf skills.local.d acme "# empty" "url = ''"
  ab_run --
  assert_rc 2
  assert_out "skills.local.d/acme.toml:2: 'url' is empty"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" && fail "session started despite the errors"
  return 0
}

# A skill source of yours from v0.1.x that a start of v0.1.x installed. The
# start converts it, and syncs nothing again: the values that it compares
# with the record stay the same.
test_convert_skill_source() {
  ss_setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/skills.local.d"
  # Of two equal keys, v0.1.x took the last.
  printf '%s\n' '# my skills' "URL=$SRC" 'ONLY=notes' 'ONLY=tdd, review' 'PREFIX=' 'SUBDIR=eng/' > "$CFG/skills.local.d/acme.conf"
  # The sync of v0.1.x, with the values that its run.sh computed.
  env HOME="$T/home" SKILLS_ONLY=review,tdd SKILLS_PREFIX= SKILLS_SUBDIR=eng AB_SKILLS_DIR="$CFG/skills" \
    SKILLS_SOURCE=acme SKILLS_PIN= bash "$AB/sync-skills.sh" "$SRC" > /dev/null 2>&1
  assert_eq "$(installed)" "review tdd"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 0
  assert_out "skills.local.d/acme.conf -> acme.toml"
  assert_out "warning: .*acme.conf:3: 'ONLY' again on line 4, kept as a comment"
  assert_no_out "syncing skills"
  assert_eq "$(cat "$CFG/skills.local.d/acme.toml")" "# my skills
url = \"$SRC\"
# ONLY=notes
only = [\"tdd\", \"review\"]
prefix = \"\"
subdir = \"eng/\""
  ab_run --
  assert_rc 0
  assert_no_out "syncing skills|converted"
  assert_eq "$(installed)" "review tdd"
}

# Old files of yours that cannot be converted. The start does not use the
# shared source or group of the same name in their place.
test_convert_failed_file_hides_no_shared_file() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "url = '$SRC'"
  mkdir -p "$CFG/skills.local.d" "$CFG/egress.local.d"
  # No URL: v0.1.x refused it too. Not a fault of agentbox.
  printf '%s\n' 'ONLY=tdd' > "$CFG/skills.local.d/acme.conf"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 2
  assert_out "acme.conf:1: the key 'URL' is missing"
  assert_no_out "fault of agentbox"
  assert_out "acme.conf was not converted to TOML .*does not use the shared skill source"
  assert_eq "$(installed)" ""
  # The same for an egress group: two hosts on one line.
  printf '%s\n' 'a.example b.example' > "$CFG/egress.local.d/pypi.conf"
  printf '%s\n' "AB_EGRESS=anthropic pypi" > "$CFG/config.env"
  ab_run --
  assert_rc 2
  assert_out "pypi.conf was not converted to TOML .*does not use the shared group"
  # The setup menu shows both as not converted, not the shared files.
  cp "$ROOT/agentbox" "$AB/"
  setup_run "q\n"
  assert_out '\[ \] acme +\(yours\) \(not converted, see the warning above\)$'
  assert_out '\[x\] pypi +\(yours\) \(not converted, see the warning above\)$'
}

# Of two equal keys, v0.1.x used the last: an error in the first does not
# stop the conversion.
test_convert_source_bad_first_key() {
  ss_setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/skills.local.d"
  printf 'URL=%s/x\x01\nURL=%s\n' "$SRC" "$SRC" > "$CFG/skills.local.d/acme.conf"
  config "AB_SKILLS=acme"
  ab_run --
  assert_rc 0
  assert_out "skills.local.d/acme.conf -> acme.toml"
}

test_skills_source_sync_failure_continues() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d broken "url = '$T/src/no/such-repo'"
  config "AB_SKILLS=broken"
  ab_run --
  assert_rc 0
  assert_out "could not sync skills from 'broken'"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" || fail "session did not start"
}

test_updates_skips_pinned_source() {
  cu_setup "${FUNCNAME[0]}"
  printf '%s\n' "URL=https://github.com/acme/skills" "COMMIT=$(printf 'a%.0s' {1..40})" \
    "SKILLS_ONLY=" "SKILLS_PREFIX=acme" "AB_SKILLS_DIR=" "SOURCE=acme" "REF=v1" > "$CFG/skills/.sources/acme__skills"
  printf 'b%.0s' {1..40} > "$T/remote_head"
  cu_run
  assert_no_out "update available: skills"
  assert_eq "$(grep -c git "$T/net")" 0 "git calls for a pinned source"
}

# --- the TOML reader ---

# toml_case <kind> <case file>: what toml_load gives, as the conformance set
# writes it: "key line endline value" for each record, sorted, then
# "file:line: code" for each error or warning.
toml_case() {
  (
    cd "$(dirname "$2")" || exit 1
    SCRIPT_DIR="$AB" XDG_CACHE_HOME="$T/home/.cache"
    ab_warn() { echo "agentbox: warning: $*" >&2; }
    # shellcheck source=/dev/null
    source "$AB/lib/toml.sh"
    declare -A values=() lines=()
    rc=0
    toml_load "$1" "$(basename "$2")" values lines 2> "$T/err" || rc=$?
    for k in "${!values[@]}"; do echo "$k ${lines[$k]} ${values[$k]}"; done | sort
    sed -E 's/^(agentbox: warning: )?([^:]+:[0-9]+): .*\(([a-z-]+)\)$/\2: \3/' "$T/err"
    exit "$rc"
  )
}

# The conformance set of the reader: each tests/toml/<kind>/<case>.toml has the expected
# records (<case>.out) or errors (<case>.err: file, line, code). A later Go
# reader must give the same results. A kind for the tests only has its
# schema in tests/toml/<kind>.schema.toml.
test_toml_conformance() {
  setup "${FUNCNAME[0]}"
  local f want got rc
  for f in "$ROOT"/tests/toml/*.schema.toml; do cp "$f" "$AB/lib/toml-schema/$(basename "$f" .schema.toml).toml"; done
  for f in "$ROOT"/tests/toml/*/*.toml; do
    want="$(cat "${f%.toml}.out" "${f%.toml}.err" 2>/dev/null)"
    rc=0; got="$(toml_case "$(basename "$(dirname "$f")")" "$f")" || rc=$?
    [[ "$got" == "$want" ]] || fail "${f#"$ROOT/"}: got"$'\n'"$got"$'\n'"expected"$'\n'"$want"
    if [[ -f "${f%.toml}.out" ]]; then assert_eq "$rc" 0 "${f#"$ROOT/"}"; else assert_eq "$rc" 2 "${f#"$ROOT/"}"; fi
  done
}

# --- main -------------------------------------------------------------------

echo "agentbox tests ($WORK)"
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  run_test "$t"
done
echo
echo "$PASSED passed, $FAILED failed"
if (( FAILED )); then
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi
