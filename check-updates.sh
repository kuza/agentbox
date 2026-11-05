#!/usr/bin/env bash
# check-updates.sh: report sidecar images and vendored skills that are behind
# upstream, and offer to update them. Runs on the HOST; run.sh calls it before
# every session with --if-due (AB_CHECK_UPDATES=0 skips it), and it can be run
# by hand, which always checks.
#
# --if-due   skip the check if the last one found nothing to do less than
#            AB_UPDATE_EVERY seconds ago (default 6h, the agent update interval).
#            Only a check that ends with nothing outstanding sets the stamp: an
#            update you declined, a failed update or an unreachable registry
#            makes the next session check again.
#
#   Images   for every agentbox sidecar container (ab-egress, ab-mcp-*,
#            ab-llm-*), compares the local digest of its image tag with the
#            registry's (an anonymous HEAD request, no pull), and flags
#            containers still running an older image than the local one.
#            Images built here (the agentbox image, its squid) have no
#            registry: a reminder to rebuild once they are a month old.
#   agentbox for an installed version (install.sh), whether a newer release
#            exists; it says so and leaves the update to `agentbox update`,
#            which verifies the release's signature first.
#   Skills   for every record sync-skills.sh keeps in
#            <skills>/.sources/<owner>__<repo> (skills directory: AB_SKILLS_DIR,
#            default <script dir>/skills), compares the installed commit with
#            the remote default branch (git ls-remote). Sources pinned to a ref
#            are skipped.
#   pi extensions  the same, for the records sync-pi-extension.sh keeps in
#            <AB_HOME>/pi-extensions.sources/<name>; an update is installed
#            only on a yes at a terminal.
#
# The skills directory is writable from a session that has the agentbox
# directory mounted, so the records are parsed as data, never sourced, and
# git runs outside any repository here: a planted hook or config would run on
# the host.
#
# Interactive (stdin and stderr are a terminal): asks before each update.
# Otherwise it only prints what is out of date.
#
# Exit status is 0 even when checks fail (no network, registry down): a
# missing update check must not block a session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/images.sh
source "$SCRIPT_DIR/lib/images.sh"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/skills.sh
source "$SCRIPT_DIR/lib/skills.sh"   # source_value, as run.sh reads the records
# shellcheck source=lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"   # IMAGE, IMG_SQUID, ab_warn
# Run by run.sh: the warnings go to its list too, for warnings_review.
# Not "could not check": offline it would come, and ask, at every start.
AB_WARNINGS_FILE="${AB_WARNINGS_TO:-}"
TIMEOUT=5
EVERY="${AB_UPDATE_EVERY:-21600}"
if [[ ! "$EVERY" =~ ^[0-9]+$ ]]; then
  echo "error: AB_UPDATE_EVERY must be a number of seconds, got '$EVERY'" >&2
  exit 2
fi
STAMP="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox.updates.checked"

if [[ "${1:-}" == --if-due && -f "$STAMP" ]] \
   && (( $(date +%s) - $(stat -c %Y "$STAMP") < EVERY )); then
  exit 0
fi

say() { echo "agentbox: $*" >&2; }
pending=0      # something to update, and no terminal to ask in
outstanding=0  # anything that should be checked again next session

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
remote_digest() {  # <image reference: [registry/]repo[:tag]; no tag means latest>
  local ref="$1" reg repo tag first url hdrs challenge realm service scope token
  local accept=(
    -H 'Accept: application/vnd.oci.image.index.v1+json'
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
    -H 'Accept: application/vnd.oci.image.manifest.v1+json'
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
  )
  # The tag follows the last ":" after the last "/"; a ":" before it is a
  # registry port (localhost:5000/x).
  if [[ "${ref##*/}" == *:* ]]; then tag="${ref##*:}"; ref="${ref%:*}"; else tag=latest; fi
  # A registry is a first component with a "." or ":", or localhost;
  # anything else is on Docker Hub (nginx -> library/nginx).
  first="${ref%%/*}"
  if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    reg="$first"; repo="${ref#*/}"
  else
    reg=docker.io; repo="$ref"
    [[ "$repo" == */* ]] || repo="library/$repo"
  fi
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
  # Pinned to a digest: the reference itself is the version, nothing to check.
  [[ "$img" == *@* ]] && continue
  # Built here (localhost/...): no registry to ask; see the age check below.
  [[ "$img" == localhost/* ]] && continue
  podman image exists "$img" || continue
  remote="$(remote_digest "$img")"
  if [[ -z "$remote" ]]; then
    say "warning: could not check $img for updates"
    outstanding=1
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
      # The replaced image is removed by run.sh once nothing uses it.
      image_retire "$img"
      podman pull -q "$img" >/dev/null \
        || { ab_warn "pull of $img failed"; outstanding=1; }
    done
    for name in "${!image_of[@]}"; do
      img="${image_of[$name]}"
      local_id="$(podman image inspect -f '{{.Id}}' "$img" 2>/dev/null)" || continue
      if [[ "$(podman inspect -f '{{.Image}}' "$name" 2>/dev/null)" != "$local_id" ]]; then
        # run.sh recreates it right after this script.
        podman rm -f -v "$name" >/dev/null && say "removed $name, recreated on start"
      fi
    done
  else
    outstanding=1
    interactive || pending=1
  fi
fi

# Images built here (the agentbox image, its squid, those of MCP modules:
# mcp/bb4) are as current as the base image they were last built on: a
# reminder once that pull is a month old (label agentbox.pulled; the build
# date for images without it). AB_UPGRADE=1 rebuilds them with today's
# packages and security updates.
built="$(podman images --filter label=agentbox.build --format '{{.Repository}}' 2>/dev/null \
  | grep '^localhost/agentbox-' | grep -vxF "$IMG_SQUID" | sort -u)" || built=""
for img in "$IMAGE" "$IMG_SQUID" $built; do
  created="$(podman image inspect -f '{{index .Labels "agentbox.pulled"}}' "$img" 2>/dev/null)" || continue
  [[ "$created" =~ ^[0-9]+$ ]] \
    || created="$(podman image inspect -f '{{.Created.Unix}}' "$img" 2>/dev/null)" || continue
  [[ "$created" =~ ^[0-9]+$ ]] || continue
  age=$(( ($(date +%s) - created) / 86400 ))
  if (( age > 30 )); then
    more=""
    [[ "$img" == "$IMAGE" || "$img" == "$IMG_SQUID" ]] \
      || more=" while its module is in AB_MCP; if it is not, remove the image: podman rmi $img"
    say "image $img was built on a base pulled $age days ago; AB_UPGRADE=1 agentbox rebuilds it with current packages$more"
  fi
done

# --- agentbox itself ---------------------------------------------------------

if release_installed; then
  latest="$(RELEASE_TIMEOUT="$TIMEOUT" release_latest)"
  if [[ -n "$latest" ]] && version_newer "${latest%% *}" "$(agentbox_version)"; then
    say "update available: agentbox $(agentbox_version) -> ${latest%% *}; run: agentbox update"
  fi
fi

# --- skills and pi extensions -----------------------------------------------

# The record <file> of a git source (URL, COMMIT, REF) against the default
# branch of its remote. On a newer commit, it says so with a link to the
# changes, and on a yes it runs <command...> with the URL as the last
# argument. A record without a URL (from before URLs were recorded) and a
# pinned one (REF in its .conf: updated by changing it) are skipped.
git_source_offer() {  # <file> <what> <command...>
  local f="$1" what="$2" url commit latest
  shift 2
  url="$(source_value "$f" URL)"
  commit="$(source_value "$f" COMMIT)"
  [[ -z "$url" ]] && return 0
  [[ -n "$(source_value "$f" REF)" ]] && return 0
  # A plain ssh URL works for the install, but the check needs https.
  if [[ "$url" =~ ^(ssh://|[A-Za-z0-9._-]+@)[A-Za-z0-9./:_~-]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    say "$what: updates are checked only for an https:// URL"
    return 0
  fi
  if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    ab_warn "$f: bad URL or COMMIT, skipped"
    return 0
  fi
  # Outside any repository, so no local git config or hooks apply.
  latest="$(cd / && GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" \
              git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}')"
  if [[ -z "$latest" ]]; then
    say "warning: could not check $url for updates"
    outstanding=1
    return 0
  fi
  [[ "$latest" == "$commit" ]] && return 0

  say "update available: $what, ${commit:0:7} -> ${latest:0:7}"
  [[ "$url" == https://github.com/* ]] \
    && say "  changes: ${url%.git}/compare/${commit:0:7}...${latest:0:7}"
  if ask "read the changes; update $what?"; then
    "$@" "$url" >&2 || { ab_warn "update of $what failed"; outstanding=1; }
  else
    outstanding=1
    interactive || pending=1
  fi
}

SKILLS_DIR="${AB_SKILLS_DIR:-$USER_SKILLS_DIR}"
shopt -s nullglob
for f in "$SKILLS_DIR"/.sources/*; do
  slug="$(basename "$f")"
  git_source_offer "$f" "skills from $slug" \
    env SKILLS_ONLY="$(source_value "$f" SKILLS_ONLY)" SKILLS_PREFIX="$(source_value "$f" SKILLS_PREFIX)" \
        SKILLS_SUBDIR="$(source_value "$f" SKILLS_SUBDIR)" \
        AB_SKILLS_DIR="$SKILLS_DIR" SKILLS_SOURCE="$(source_value "$f" SOURCE)" SKILLS_PIN="" \
        "$SCRIPT_DIR/sync-skills.sh"
done

# pi extensions: an extension is code that pi runs, so an update needs a
# yes. Not at a start of another agent (run.sh passes it): only a start of
# pi installs them. Run by hand, the enabled list comes from config.env.
if [[ -z "${AB_PI_EXTENSIONS_ENABLED+x}" && -f "$CONFIG_FILE" ]]; then
  AB_PI_EXTENSIONS_ENABLED=" $(unset AB_PI_EXTENSIONS; load_config "$CONFIG_FILE" 0 AB_PI_EXTENSIONS; echo "${AB_PI_EXTENSIONS:-}") "
fi
pi_records=("$USER_PI_EXTENSIONS_RECORDS"/*)
[[ "${AB_CHECK_AGENT:-pi}" == pi ]] || pi_records=()
for f in ${pi_records[@]+"${pi_records[@]}"}; do
  name="$(basename "$f")"
  [[ "$name" =~ $AB_NAME_RE ]] || continue
  # A source that is disabled now, whose record only the next start of pi
  # removes, gets no offer.
  if [[ -n "${AB_PI_EXTENSIONS_ENABLED+x}" && "$(source_value "$f" SOURCE)" == 1 ]]; then
    list="${AB_PI_EXTENSIONS_ENABLED//,/ }"
    [[ "$list" == *" $name "* ]] || continue
  fi
  git_source_offer "$f" "pi extension $name" \
    env AB_PI_EXTENSIONS_PIN="" AB_PI_EXTENSIONS_SOURCE="$(source_value "$f" SOURCE)" \
        "$SCRIPT_DIR/sync-pi-extension.sh" "$name"
done

(( pending )) && say "to update, run $SCRIPT_DIR/check-updates.sh in a terminal"
if (( ! outstanding )); then
  mkdir -p "$(dirname "$STAMP")" && touch "$STAMP"
fi
exit 0
