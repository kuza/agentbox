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
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(AB_|SKILLS_|XDG_)')

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentbox-tests.XXXXXX")"
trap 'rm -rf -- "${WORK:?}"' EXIT
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
  cp -R "$ROOT/run.sh" "$ROOT/pi.sh" "$ROOT/lib" "$ROOT/mcp" "$ROOT/squid.conf" "$ROOT/egress.d" "$ROOT/skills.d" \
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
  ab_run AB_UPGRADE=1 STUB_BUILT_ID=img-2 STUB_PULL_NEW="docker.io/ubuntu/squid:latest" STUB_RMI_FAIL=img-1 --
  assert_rc 0
  grep -qx 'podman rmi id-docker.io/ubuntu/squid:latest' "$STUB_DIR/calls" || fail "old squid image not removed"
  grep -q '^podman rmi id-docker.io/library/nginx' "$STUB_DIR/calls" && fail "current nginx image removed"
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
  # A separate clone of agentbox is an ordinary repo.
  cp -R "$AB" "$T/clone"
  REPO="$T/clone"
  ab_run --
  assert_rc 0
}

test_user_files_in_old_place_used_with_warning() {
  setup "${FUNCNAME[0]}"
  mkdir -p "$AB/env" "$AB/agents"
  echo "DB=x" > "$AB/env/repo.env"
  echo "# rules" > "$AB/agents/AGENTS.md"
  rm "$CFG/config.env"
  echo "AB_SERVICES=" > "$AB/config.env"
  ab_run --
  assert_rc 0
  assert_out "your files belong in $CFG now"
  assert_out "mv '$AB/env' '$CFG/env'"
  assert_out "mv '$AB/agents/AGENTS.md' '$CFG/AGENTS.md'"
  assert_out "mv '$AB/config.env' '$CFG/config.env'"
  local args; args="$(session_args)"
  grep -qx -- "$AB/env/repo.env" <<<"$args" || fail "old env file not used"
  grep -qx -- "$AB/agents/AGENTS.md:/home/node/.claude/CLAUDE.md:ro,z" <<<"$args" || fail "old AGENTS.md not used"
  # Once moved, the new place wins and the warning goes.
  mv "$AB/env" "$CFG/env"; mv "$AB/agents/AGENTS.md" "$CFG/AGENTS.md"; mv "$AB/config.env" "$CFG/config.env"
  ab_run --
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
