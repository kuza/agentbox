#!/usr/bin/env bash
# check-updates.sh: report sidecar images and vendored skills that are behind
# upstream, and offer to update them. Runs on the HOST; run.sh calls it before
# every session (AB_CHECK_UPDATES=0 skips it), and it can be run by hand.
#
#   Images   for every agentbox sidecar container (ab-egress, ab-mcp-*,
#            ab-llm-*), compares the local digest of its image tag with the
#            registry's (an anonymous HEAD request, no pull), and flags
#            containers still running an older image than the local one.
#   Skills   for every vendor/<owner>__<repo>.sync written by sync-skills.sh,
#            compares the installed commit with the remote default branch
#            (git ls-remote).
#
# vendor/ and skills/ are writable from a session that has the agentbox
# directory mounted, so .sync files are parsed as data, never sourced, and git
# never runs inside vendor/ here: a planted hook or config there would run on
# the host.
#
# Interactive (stdin and stderr are a terminal): asks before each update.
# Otherwise it only prints what is out of date.
#
# Exit status is 0 even when checks fail (no network, registry down): a
# missing update check must not block a session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT=5

say() { echo "agentbox: $*" >&2; }
pending=0

interactive() { [[ -t 0 && -t 2 ]]; }

ask() {  # <question>; true on yes
  local reply
  interactive || return 1
  read -r -p "agentbox: $1 [y/N] " reply </dev/tty || return 1
  [[ "$reply" == [yY]* ]]
}

# --- images -----------------------------------------------------------------

# Digest the registry serves for an image tag (manifest list for multi-arch
# images). Empty on any failure.
remote_digest() {  # <registry/repo:tag>
  local ref="$1" reg rest repo tag url hdrs challenge realm service scope token
  local accept=(
    -H 'Accept: application/vnd.oci.image.index.v1+json'
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
    -H 'Accept: application/vnd.oci.image.manifest.v1+json'
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
  )
  reg="${ref%%/*}"; rest="${ref#*/}"
  repo="${rest%:*}"; tag="${rest##*:}"
  [[ "$reg" == docker.io ]] && reg=registry-1.docker.io
  url="https://$reg/v2/$repo/manifests/$tag"

  hdrs="$(curl -sI --max-time "$TIMEOUT" "${accept[@]}" "$url" | tr -d '\r')" || return 0
  if [[ "$(head -n1 <<<"$hdrs")" == *" 401"* ]]; then
    # Anonymous bearer token, as the registry's challenge describes.
    challenge="$(grep -i '^www-authenticate: *bearer' <<<"$hdrs")"
    realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")"
    service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")"
    scope="$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$challenge")"
    [[ "$realm" == https://* ]] || return 0
    token="$(curl -s --max-time "$TIMEOUT" -G "$realm" \
               --data-urlencode "service=$service" --data-urlencode "scope=$scope" \
             | sed -n 's/.*"\(access_\)\{0,1\}token" *: *"\([^"]*\)".*/\2/p')"
    [[ -n "$token" ]] || return 0
    hdrs="$(curl -sI --max-time "$TIMEOUT" "${accept[@]}" \
              -H "Authorization: Bearer $token" "$url" | tr -d '\r')" || return 0
  fi
  grep -i '^docker-content-digest:' <<<"$hdrs" | awk '{print $2}'
}

declare -A image_of=() stale=()   # container -> image tag; outdated tags
while IFS=' ' read -r name image; do
  [[ "$name" =~ ^ab-(egress|mcp-.+|llm-.+)$ ]] && image_of[$name]="$image"
done < <(podman ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null)

images=()
if (( ${#image_of[@]} )); then
  mapfile -t images < <(printf '%s\n' "${image_of[@]}" | sort -u)
fi
for img in ${images[@]+"${images[@]}"}; do
  podman image exists "$img" || continue
  remote="$(remote_digest "$img")"
  if [[ -z "$remote" ]]; then
    say "warning: could not check $img for updates"
    continue
  fi
  if ! podman image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$img" \
       | grep -q "@$remote\$"; then
    stale[$img]=1
    say "update available: image $img"
  fi
done

# Containers running an older image than the local one of the same tag
# (pulled earlier, never recreated).
old_containers=()
for name in "${!image_of[@]}"; do
  img="${image_of[$name]}"
  [[ -n "${stale[$img]:-}" ]] && continue
  local_id="$(podman image inspect -f '{{.Id}}' "$img" 2>/dev/null)" || continue
  if [[ "$(podman inspect -f '{{.Image}}' "$name" 2>/dev/null)" != "$local_id" ]]; then
    old_containers+=("$name")
    say "container $name runs an older image than the local $img"
  fi
done

if (( ${#stale[@]} + ${#old_containers[@]} )); then
  if ask "pull new images and recreate the affected sidecars? (open sessions lose MCP until restarted)"; then
    for img in "${!stale[@]}"; do
      say "pulling $img"
      podman pull -q "$img" >/dev/null || say "warning: pull of $img failed"
    done
    for name in "${!image_of[@]}"; do
      img="${image_of[$name]}"
      local_id="$(podman image inspect -f '{{.Id}}' "$img" 2>/dev/null)" || continue
      if [[ "$(podman inspect -f '{{.Image}}' "$name" 2>/dev/null)" != "$local_id" ]]; then
        # run.sh recreates it right after this script.
        podman rm -f "$name" >/dev/null && say "removed $name, recreated on start"
      fi
    done
  elif ! interactive; then
    pending=1
  fi
fi

# --- skills -----------------------------------------------------------------

# KEY=VALUE from a .sync file, without evaluating it.
sync_value() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n1
}

shopt -s nullglob
for f in "$SCRIPT_DIR"/vendor/*.sync; do
  slug="$(basename "$f" .sync)"
  url="$(sync_value "$f" URL)"
  commit="$(sync_value "$f" COMMIT)"
  if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    say "warning: $f: bad URL or COMMIT, skipped"
    continue
  fi
  # Outside any repository, so no local git config or hooks apply.
  latest="$(cd / && GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" \
              git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}')"
  if [[ -z "$latest" ]]; then
    say "warning: could not check $url for updates"
    continue
  fi
  [[ "$latest" == "$commit" ]] && continue

  say "update available: skills from $slug, ${commit:0:7} -> ${latest:0:7}"
  [[ "$url" == https://github.com/* ]] \
    && say "  changes: ${url%.git}/compare/${commit:0:7}...${latest:0:7}"
  only="$(sync_value "$f" SKILLS_ONLY)"
  prefix="$(sync_value "$f" SKILLS_PREFIX)"
  skills_dir="$(sync_value "$f" AB_SKILLS_DIR)"
  if ask "update skills from $slug?"; then
    SKILLS_ONLY="$only" SKILLS_PREFIX="$prefix" AB_SKILLS_DIR="$skills_dir" \
      "$SCRIPT_DIR/sync-skills.sh" "$url" >&2 \
      || say "warning: skills update from $slug failed"
  elif ! interactive; then
    pending=1
  fi
done

(( pending )) && say "to update, run $SCRIPT_DIR/check-updates.sh in a terminal"
exit 0
