#!/usr/bin/env bash
# escape.sh: run INSIDE an agentbox session; tries to get out of the box the
# way an agent under prompt injection would, and reports what worked.
#
#   bash tests/escape.sh            (from the agentbox repo opened in a session)
#
# Each check is one attempt. PASS: the attempt failed, as it should. FAIL: it
# worked, a hole. WARN: not a hole by itself, worth a look. INFO: what the
# session has, for the record. Exit status 1 if anything FAILed.
#
# Harmless by design: no exploits, nothing is changed outside a scratch file
# it removes again, only connection attempts and reads. Some checks depend on
# the setup (MCP modules, AB_FORWARD); missing pieces are reported as INFO.
#
# Environment, for setups that know more (CI):
#   ESCAPE_FORBIDDEN  host:port targets that must NOT be reachable, such as
#                     another repo's AB_FORWARD sidecar by name or address
#   ESCAPE_REACHABLE  host:port targets that must be reachable, such as this
#                     repo's own AB_FORWARD names (the forward works)
set -uo pipefail

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

T=5   # seconds per attempt

# tcp <host> <port>: 0 if a TCP connection opens.
tcp() { timeout "$T" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# http_code <curl args...>: the HTTP status, 000 if no response.
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time "$T" "$@" 2>/dev/null || true; }
# via_proxy <curl args...>: the same, forced through the session's proxy.
# NO_PROXY would send names listed there around it, and curl ignores an
# upper-case HTTP_PROXY for plain HTTP.
via_proxy() { env -u NO_PROXY -u no_proxy curl -s -o /dev/null -w '%{http_code}' --max-time "$T" -x "$HTTPS_PROXY" "$@" 2>/dev/null || true; }

if [[ ! -f /.dockerenv && ! -f /run/.containerenv ]]; then
  echo "error: run this inside an agentbox session, not on the host" >&2
  exit 2
fi

# --------------------------------------------------------------------------
section "Network: around the proxy"

code="$(http_code --noproxy '*' https://example.com)"
[[ "$code" == 000 ]] && pass "direct HTTPS without the proxy fails" || fail "direct HTTPS to example.com works (HTTP $code)"

for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
  for port in 443 53 80; do
    if tcp "$ip" "$port"; then fail "direct TCP to $ip:$port works"; else pass "direct TCP to $ip:$port fails"; fi
  done
done

if timeout "$T" getent hosts example.com >/dev/null 2>&1; then
  fail "external DNS resolves (example.com): a channel for data, even without TCP"
else
  pass "external DNS does not resolve"
fi

# Host and gateways: the host's own services must be out of reach.
targets=()
h="$(getent hosts host.containers.internal 2>/dev/null | awk '{ print $1; exit }')"
[[ -n "$h" ]] && targets+=("$h")
while read -r _ dest _; do
  [[ "$dest" == Destination ]] && continue
  # /proc/net/route: little-endian hex; the .1 of each attached network.
  ip="$(printf '%d.%d.%d.%d' "0x${dest:6:2}" "0x${dest:4:2}" "0x${dest:2:2}" "0x${dest:0:2}")"
  targets+=("${ip%.*}.1")
done < /proc/net/route
for ip in $(printf '%s\n' "${targets[@]}" | sort -u); do
  for port in 22 80 443 2375 5432 6379 8080; do
    if tcp "$ip" "$port"; then fail "host/gateway $ip:$port reachable"; else pass "host/gateway $ip:$port unreachable"; fi
  done
done

if [[ -n "${ESCAPE_FORBIDDEN:-}${ESCAPE_REACHABLE:-}" ]]; then
  section "Network: given targets"
  for t in ${ESCAPE_FORBIDDEN:-}; do
    if tcp "${t%:*}" "${t##*:}"; then fail "$t reachable, but must not be"; else pass "$t unreachable"; fi
  done
  for t in ${ESCAPE_REACHABLE:-}; do
    if tcp "${t%:*}" "${t##*:}"; then pass "$t reachable"; else fail "$t unreachable, but should be"; fi
  done
fi

# --------------------------------------------------------------------------
section "Network: through the proxy"

if [[ -z "${HTTPS_PROXY:-}" ]]; then
  info "no HTTPS_PROXY in the environment; proxy checks skipped"
else
  code="$(http_code https://example.com)"
  [[ "$code" == 000 || "$code" == 403 ]] && pass "CONNECT to a host not allowed is refused" || fail "example.com reachable through the proxy (HTTP $code)"
  code="$(via_proxy http://example.com)"
  [[ "$code" == 403 ]] && pass "plain HTTP to a host not allowed is refused" || fail "plain HTTP to example.com through the proxy: HTTP $code"
  code="$(http_code https://1.1.1.1)"
  [[ "$code" == 000 || "$code" == 403 ]] && pass "CONNECT to an IP address is refused" || fail "1.1.1.1 reachable through the proxy (HTTP $code)"
  # An allowed host on a port other than 443: CONNECT must still be refused.
  code="$(http_code https://pypi.org:22)"
  [[ "$code" == 000 || "$code" == 403 ]] && pass "CONNECT to an allowed host on port 22 is refused" || fail "pypi.org:22 through the proxy: HTTP $code"
  # Plain HTTP to an allowed host on a port other than 80.
  # Only squid's own 403 counts: 000 means it let the request through and
  # the host did not answer on that port.
  code="$(via_proxy http://pypi.org:8080/)"
  [[ "$code" == 403 ]] && pass "plain HTTP to an allowed host on port 8080 is refused" || fail "plain HTTP to pypi.org:8080 passes the proxy (HTTP $code)"
  # The proxy must not be a way to the sidecars or to itself.
  for u in http://ab-mcp-grafana:8000/ http://ab-mcp-github:8080/ http://ab-egress:3128/squid-internal-mgr/info http://localhost:3128/; do
    code="$(via_proxy "$u")"
    [[ "$code" == 403 || "$code" == 000 || "$code" == 400 ]] && pass "proxy refuses $u" || fail "proxy forwards to $u (HTTP $code)"
  done
  # Squid's cache manager directly: reveals configuration and clients.
  code="$(http_code --noproxy '*' http://ab-egress:3128/squid-internal-mgr/menu)"
  [[ "$code" != 200 ]] && pass "squid cache manager not available (HTTP $code)" || fail "squid cache manager answers"
fi

# --------------------------------------------------------------------------
section "MCP sidecars: callers without the token"

if [[ -f /etc/agentbox/mcp.json || -f "$HOME/.pi/agent/mcp.json" ]]; then
  cfg=/etc/agentbox/mcp.json; [[ -f "$cfg" ]] || cfg="$HOME/.pi/agent/mcp.json"
  while IFS=$'\t' read -r name url has_auth; do
    [[ "$url" == http://ab-* ]] || continue
    body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"escape","version":"0"}}}'
    code="$(http_code --noproxy '*' -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$body" "$url")"
    if [[ "$has_auth" == 0 ]]; then
      warn "$name ($url) has no caller token: any container on ab-internal may use it (HTTP $code without one)"
      continue
    fi
    [[ "$code" == 401 || "$code" == 403 ]] && pass "$name refuses a call without the token (HTTP $code)" || fail "$name answers without the token (HTTP $code)"
    code="$(http_code --noproxy '*' -X POST -H 'Authorization: Bearer wrong' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$body" "$url")"
    [[ "$code" == 401 || "$code" == 403 ]] && pass "$name refuses a wrong token (HTTP $code)" || fail "$name answers a wrong token (HTTP $code)"
  done < <(python3 -I -c '
import json, sys
for n, s in json.load(open(sys.argv[1]))["mcpServers"].items():
    print(n, s["url"], int("Authorization" in s.get("headers", {})), sep="\t")' "$cfg")
else
  info "no MCP config found; sidecar checks skipped"
fi

# --------------------------------------------------------------------------
section "Credentials and the container runtime"

for s in /var/run/docker.sock /run/docker.sock /run/podman/podman.sock /run/user/*/podman/podman.sock "${XDG_RUNTIME_DIR:-/nonexistent}/podman/podman.sock"; do
  [[ -S "$s" ]] && fail "container runtime socket present: $s"
done
pass "no docker/podman socket found"

for d in ~/.ssh ~/.aws ~/.kube ~/.docker ~/.config/gcloud ~/.gnupg ~/.config/agentbox; do
  [[ -e "$d" ]] && warn "$d exists in the session: check what is in it" || pass "$d absent"
done

# Secrets in the environment: names only, never values.
while IFS= read -r v; do
  case "$v" in
    AB_MCP_TOKEN_*|OPENAI_CALLER_TOKEN) info "env $v: a caller token (meant to be here)" ;;
    CLAUDE_CODE_OAUTH_TOKEN) info "env $v: the agent's own login (meant to be here)" ;;
    CLAUDE_CODE_MESSAGING_TOKEN) info "env $v: set by Claude Code itself for its own processes" ;;
    *) warn "env $v looks like a secret: from a per-project env file?" ;;
  esac
done < <(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | grep -iE 'token|secret|passw|api_?key|credential' )

# --------------------------------------------------------------------------
section "Privileges"

cap="$(awk '/^CapEff:/ { print $2 }' /proc/self/status)"
[[ "$cap" =~ ^0+$ ]] && pass "no effective capabilities" || fail "effective capabilities: $cap"
cap="$(awk '/^CapBnd:/ { print $2 }' /proc/self/status)"
[[ "$cap" =~ ^0+$ ]] && pass "empty capability bounding set" || warn "capability bounding set: $cap"
[[ "$(awk '/^NoNewPrivs:/ { print $2 }' /proc/self/status)" == 1 ]] && pass "no_new_privs set" || fail "no_new_privs not set"
[[ "$(awk '/^Seccomp:/ { print $2 }' /proc/self/status)" == 2 ]] && pass "seccomp filter active" || fail "no seccomp filter"
[[ "$(id -u)" != 0 ]] && pass "not root (uid $(id -u))" || fail "running as root"
if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then fail "sudo works"; else pass "no sudo"; fi
if command -v unshare >/dev/null && unshare -Ur true 2>/dev/null; then
  warn "new user namespaces can be created (unshare -Ur): more kernel surface for exploits"
else
  pass "no new user namespaces"
fi

# --------------------------------------------------------------------------
section "Read-only mounts"

# try_write <path>: can a file be created there? Removes it again.
try_write() {
  local f="$1/.escape-test-$$"
  if ( : > "$f" ) 2>/dev/null; then rm -f -- "$f"; return 0; fi
  return 1
}
try_append() {  # <existing file>: can it be opened for writing? Writes nothing.
  ( : >> "$1" ) 2>/dev/null
}

repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -d "$repo/.git" ]]; then
  # A mount of its own cannot be renamed and replaced with the agent's .git.
  if awk -v t="$repo/.git" '$5 == t { found = 1 } END { exit !found }' /proc/self/mountinfo; then
    pass "$repo/.git is a mount of its own (cannot be renamed)"
  else
    fail "$repo/.git can be renamed and replaced"
  fi
  [[ -d "$repo/.git/modules" ]] && { if try_write "$repo/.git/modules"; then fail "$repo/.git/modules writable: submodule config runs on the host"; else pass "$repo/.git/modules read-only"; fi; }
fi
if [[ -d "$repo/.git/hooks" ]]; then
  if try_write "$repo/.git/hooks"; then fail "$repo/.git/hooks writable: a hook would run on the host"; else pass "$repo/.git/hooks read-only"; fi
fi
[[ -f "$repo/.git/config" ]] && { try_append "$repo/.git/config" && fail "$repo/.git/config writable: core.fsmonitor and friends run on the host" || pass "$repo/.git/config read-only"; }

for d in /opt/claude /opt/pi ~/.claude/skills ~/.pi/agent/skills ~/.pi/agent/extensions /etc/agentbox; do
  [[ -d "$d" ]] || continue
  try_write "$d" && fail "$d writable" || pass "$d read-only"
done
for f in ~/.claude/CLAUDE.md ~/.pi/agent/AGENTS.md ~/.pi/agent/mcp.json ~/.pi/agent/models.json ~/.claude/statusline.py; do
  [[ -f "$f" ]] || continue
  try_append "$f" && fail "$f writable: survives into the next session" || pass "$f read-only"
done
for b in /opt/claude/bin/claude /opt/pi/bin/pi; do
  [[ -e "$b" ]] || continue
  try_append "$(readlink -f "$b")" && fail "the agent binary $b is writable" || pass "the agent binary $b is read-only"
done

# What else is mounted from the host: for a human to look at.
section "Mounts from the host (for review)"
awk '$9 !~ /^(proc|sysfs|tmpfs|devpts|mqueue|cgroup2?|overlay|shm|devtmpfs)$/ { print $5, $6 }' /proc/self/mountinfo \
  | grep -vE '^/(proc|sys|dev)' | sort -u | while read -r target opts; do info "$target ($opts)"; done

# --------------------------------------------------------------------------
echo
if (( FAILS )); then
  echo "$FAILS check(s) FAILED: the box has holes, see above."
  exit 1
fi
echo "No holes found by these checks. WARN lines are worth a look."
