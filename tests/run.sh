#!/usr/bin/env bash
# Tests for run.sh (with lib/ and mcp/), check-updates.sh and sync-skills.sh.
# No podman, network or registry needed: podman, curl and the remote git
# side are stand-ins (tests/stub/podman, fake curl, local repositories).
#
#   tests/run.sh            all tests
#   tests/run.sh mcp_       tests whose name starts with "mcp_"
#
# Each test runs in its own scratch directory with a copy of agentbox's code,
# never the real config.env or skills/. Needs bash 4+, git, and
# python3 for the JSON checks (skipped without it).
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
  cp -R "$ROOT/run.sh" "$ROOT/pi.sh" "$ROOT/Containerfile" "$ROOT/Containerfile.squid" "$ROOT/lib" "$ROOT/mcp" "$ROOT/squid.conf" "$ROOT/egress.d" "$ROOT/skills.d" \
        "$ROOT/check-updates.sh" "$ROOT/sync-skills.sh" "$AB/" 2>/dev/null
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
  config "AB_MCP=graylog" "GRAYLOG_URL=https://graylog.example"
  ab_run --
  assert_rc 1
  assert_out 'missing podman secrets for MCP modules: graylog_basic \(graylog\)'
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" && fail "session must not start"
}

test_mcp_missing_setting() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana"
  secrets grafana_sa
  ab_run --
  assert_rc 2
  assert_out "MCP module 'grafana' needs GRAFANA_URL"
}

test_mcp_unknown_module() {
  setup "${FUNCNAME[0]}"
  config "AB_MCP=grafana jira"
  ab_run --
  assert_rc 2
  assert_out "no MCP module 'jira'"
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

test_mcp_config_keys_of_disabled_module_warn() {
  setup "${FUNCNAME[0]}"
  config "GRAFANA_URL=https://grafana.example" "NO_SUCH_KEY=1"
  ab_run --
  assert_rc 0
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
  assert_file_lacks "$f" 'github.com|storage.googleapis.com'
  grep -q 'squid-allow.conf:/etc/squid/agentbox-allow.conf:ro,Z' "$STUB_DIR/calls" || fail "include not mounted"
}

test_egress_listed_groups_local_override_and_ports() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$CFG/egress.local.d"
  printf '%s\n' '# test servers' 'Data.S3.eu-central-1.amazonaws.com' 'minio.test:9000  # MinIO' \
    '.internal.example' > "$CFG/egress.local.d/test.conf"
  printf '%s\n' 'mirror.example' > "$CFG/egress.local.d/pypi.conf"
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
  printf '%s\n' 'ok.example' 'bad host; http_access allow all' > "$CFG/egress.local.d/bad.conf"
  : > "$CFG/config.env"; config "AB_EGRESS=bad"
  ab_run --
  assert_rc 2
  assert_out "bad.conf:2: one host per line"
  grep -q '^podman run -d' "$STUB_DIR/calls" && fail "sidecars started despite the error"
  : > "$CFG/config.env"
  local h
  for h in 'x.example:99999' 'x.example:0' 'x_y.example' '*.example' 'x.example:443/path'; do
    printf '%s\n' "$h" > "$CFG/egress.local.d/bad.conf"
    config "AB_EGRESS=bad"
    ab_run --
    assert_rc 2
    assert_out "is not a host name"
  done
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

# --- run.sh: forwards ---

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
  local bridge; bridge="$(cache tabularis)/bridge-$(cat "$AB/mcp/tabularis/bridge/package.json" "$AB/mcp/tabularis/bridge/package-lock.json" | sha256sum | cut -c1-16)"
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
  local new; new="$base/bridge-$(cat "$AB/mcp/tabularis/bridge/package.json" "$AB/mcp/tabularis/bridge/package-lock.json" | sha256sum | cut -c1-16)"
  bridge_line | grep -qF -- "$new/node_modules" || fail "bridge not restarted on the new install: $(bridge_line)"
  [[ -e "$old" ]] || fail "a recent install removed"
  touch -d '40 days ago' "$old" "$new"
  ab_run AB_TABULARIS_WAIT=0 --
  [[ -e "$old" ]] && fail "an install unused for 40 days kept"
  [[ -e "$new" ]] || fail "the install in use removed"
  # npm ci fails: the start stops and says so.
  echo " " >> "$AB/mcp/tabularis/bridge/package-lock.json"
  ab_run AB_TABULARIS_WAIT=0 STUB_NPM_FAIL=1 --
  assert_rc 1
  assert_out "could not install the tabularis bridge: npm ci failed"
  grep -q '^podman run --rm -i' "$STUB_DIR/calls" && fail "session started without its enabled module"
  ls -d "$base"/.install.* 2>/dev/null && fail "failed install left"
  # A leftover older than an hour goes; a half install is replaced.
  mkdir -p "$base/.install.old"; touch -d '2 hours ago' "$base/.install.old"
  local half; half="$base/bridge-$(cat "$AB/mcp/tabularis/bridge/package.json" "$AB/mcp/tabularis/bridge/package-lock.json" | sha256sum | cut -c1-16)"
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
  assert_rc 1
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
  assert_rc 1
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
  ab_run AB_TABULARIS_WAIT=0 --
  kill "$pid" 2>/dev/null
  assert_rc 1
  assert_out "TABULARIS_PORT $(cat "$T/port") on 127.0.0.1 is in use by another program"
  grep -q '^systemd-run' "$STUB_DIR/calls" && fail "bridge started on a taken port"
  assert_eq "$(started)" "ab-egress" "sidecars"
}

test_tabularis_errors() {
  tab_setup "${FUNCNAME[0]}"
  config 'TABULARIS_CMD=tabularis $(touch x)'
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 2
  assert_out "TABULARIS_CMD may hold only"
  local p
  for p in 80 08080 70000; do
    : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_PORT=$p"
    ab_run AB_TABULARIS_WAIT=0 --
    assert_rc 2
    assert_out "TABULARIS_PORT must be a port from 1024 to 65535, got '$p'"
  done
  : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_CMD=./bin/tabularis"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 2
  assert_out "give the command by name or as an absolute path, got './bin/tabularis'"
  : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_CMD= tabularis"
  ab_run AB_TABULARIS_WAIT=0 TABULARIS_CMD=" tabularis" --
  assert_rc 2
  assert_out "starts with the command"
  : > "$CFG/config.env"; config "AB_MCP=tabularis" "TABULARIS_CMD=no-such-tabularis"
  ab_run AB_TABULARIS_WAIT=0 --
  assert_rc 1
  assert_out "'no-such-tabularis' not found"
  grep -q '^systemd-run' "$STUB_DIR/calls" && fail "bridge started despite the error"
  return 0
}

test_skill_sources_same_repository() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d a "URL=$SRC" "ONLY=tdd"
  src_conf skills.d b "URL=$SRC" "ONLY=review"
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
  readme="$(awk '/^`~\/.local\/bin` must come first/ { on = 1 } on && /^```$/ { n++; next } on && n == 1 { print } n == 2 { exit }' "$ROOT/README.md")"
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
  printf '%s\n' "ab-mcp-grafana x" "ab-claude-7 localhost/agentbox" "redis docker.io/library/redis:7" > "$STUB_DIR/running"
  printf '%s\n' ab-claude-home ab-cache mydata > "$STUB_DIR/volumes"
  printf '%s\n' ab-internal ab-services podman > "$STUB_DIR/networks"
  printf '%s\n' "ab-services redis" "ab-services ab-claude-7" > "$STUB_DIR/netconns"
  printf '%s\n' claude_oauth grafana_sa grafana_mcp_caller tabularis_bridge_key mine > "$STUB_DIR/secrets"
  printf '%s\n' "agentbox-mcp-tabularis.service agentbox host service [abc]" "agentbox-mine.service my own" > "$STUB_DIR/units"
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
  assert_eq "$(paste -sd' ' "$STUB_DIR/secrets")" "claude_oauth grafana_sa grafana_mcp_caller tabularis_bridge_key mine" "secrets kept"
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
  assert_eq "$(paste -sd' ' "$STUB_DIR/secrets")" "mine" "secrets after --all"
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
# <input> typed into it.
tty_run() {
  local input="$1"; shift
  local envs=()
  while (( $# )) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  : > "$STUB_DIR/calls"
  printf '%b' "$input" | script -qec "$(printf '%q ' env HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" \
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
  tty_run 'y\nsk-ant-oat01-first\n' --
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
  setup_run "q\n"
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
  mkdir -p "$CFG/egress.local.d"; echo corp.example > "$CFG/egress.local.d/corp.net.conf"
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
  echo x > "$CFG/egress.local.d/my group.conf"
  mkdir -p "$CFG/mcp.local/broken"; echo 'MCP_DESCRIPTION=x' > "$CFG/mcp.local/broken/mcp.sh"
  local broken; broken="$(setup_entry broken)"
  setup_run "$broken\ns\n"
  assert_out "my group .*cannot be used"
  assert_out "module broken cannot be read"
  assert_out "nothing to save"
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
  assert_eq "$(head -n1 "$T/out")" "agentbox dev ($AB)" "banner from a clone"
  echo v1.0.0 > "$AB/VERSION"
  ab_run --
  assert_eq "$(head -n1 "$T/out")" "agentbox v1.0.0" "banner of a release"
  rm "$AB/VERSION"
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
  mkdir -p "$T/home/.local/share/agentbox/versions/v9.9.9" "$T/home/.local/bin"
  for r in "$T/home/.local/share/agentbox/versions/v9.9.9" "$T/home/.local/bin"; do
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

test_sync_bad_prefix() {
  ss_setup "${FUNCNAME[0]}"
  ss_run SKILLS_PREFIX=Bad
  assert_rc 1
  assert_out "must be lowercase"
}


# --- run.sh: skill sources (AB_SKILLS) --------------------------------------

src_conf() {  # <dir: skills.d|skills.local.d> <name> <lines...>
  local dir name="$2"
  if [[ "$1" == skills.d ]]; then dir="$AB/$1"; else dir="$CFG/$1"; fi
  shift 2
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/$name.conf"
}
installed() { ls "$CFG/skills" 2>/dev/null | grep -v '^graphify$' | paste -sd' ' -; }

test_skills_source_installed_once() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "URL=$SRC" "ONLY=tdd,review"
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
  src_conf skills.d acme "URL=$SRC" "ONLY=tdd"
  config "AB_SKILLS=acme"
  ab_run --
  local before; before="$(source_value "$CFG/skills/.sources/acme__skills" COMMIT)"
  printf -- '---\nname: tdd\n---\nNewer.\n' > "$SRC/eng/tdd/SKILL.md"
  git -C "$SRC" -c user.name=t -c user.email=t@t commit -qam newer
  src_conf skills.d acme "URL=$SRC" "ONLY=tdd,notes"
  ab_run --
  assert_rc 0
  assert_eq "$(installed)" "acme-notes acme-tdd"
  assert_eq "$(source_value "$CFG/skills/.sources/acme__skills" COMMIT)" "$before" "installed commit"
  assert_file_lacks "$CFG/skills/acme-tdd/SKILL.md" 'Newer'
  assert_eq "$(source_value "$CFG/skills/.sources/acme__skills" REF)" "" "REF (must not look pinned)"
}

test_skills_source_disabled_removed_manual_kept() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d acme "URL=$SRC" "ONLY=tdd"
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
  src_conf skills.d acme "URL=$SRC" "ONLY=tdd" "REF=$first"
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
  src_conf skills.d acme "URL=$SRC" "ONLY=tdd"
  src_conf skills.local.d acme "URL=$SRC" "ONLY=review" "PREFIX="
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
}

test_skills_source_sync_failure_continues() {
  ss_setup "${FUNCNAME[0]}"
  src_conf skills.d broken "URL=$T/src/no/such-repo"
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
