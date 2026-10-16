# Releases: the installed agentbox, its version, update and rollback.
#
#   <AB_INSTALL_DIR>                 default ~/.local/share/agentbox
#     versions/<version>/            one release each, read-only
#     current -> versions/<version>  what ~/.local/bin/agentbox runs
#     previous                       the version before the last switch
#
# A release is a GitHub release of AB_RELEASE_REPO (default kuza/agentbox)
# with agentbox-<version>.tar.gz and its SSH signature (.sig), both made by
# release.sh. An update is installed only if the signature verifies against
# release/allowed_signers of the version running now, so a new signing key
# becomes trusted only through a release signed by a key trusted already.
#
# Sourced by the agentbox command, install.sh and check-updates.sh; needs
# SCRIPT_DIR.

RELEASE_NAMESPACE=agentbox-release
INSTALL_DIR="${AB_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agentbox}"
RELEASE_REPO="${AB_RELEASE_REPO:-kuza/agentbox}"
RELEASE_API="${AB_RELEASE_API:-https://api.github.com}"
VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

# The release tag git archive wrote into VERSION; "dev" in a clone.
agentbox_version() {  # [dir]
  local v
  v="$(head -n1 "${1:-$SCRIPT_DIR}/VERSION" 2>/dev/null)"
  if [[ "$v" =~ $VERSION_RE ]]; then echo "$v"; else echo dev; fi
}

# release_verify <tarball> <signature> <allowed_signers>: 0 if a trusted key
# signed the tarball for agentbox releases.
release_verify() {
  local principal
  principal="$(ssh-keygen -Y find-principals -s "$2" -f "$3" 2>/dev/null | head -n1)"
  [[ -n "$principal" ]] || return 1
  ssh-keygen -Y verify -f "$3" -I "$principal" -n "$RELEASE_NAMESPACE" -s "$2" < "$1" >/dev/null 2>&1
}

# release_latest: prints "<tag> <tarball URL> <signature URL>" of the newest
# release, nothing if it cannot be found. JSON is read with sed: the host may
# have no python.
release_latest() {
  local json tag tar sig
  json="$(curl -fsSL --max-time "${RELEASE_TIMEOUT:-20}" "$RELEASE_API/repos/$RELEASE_REPO/releases/latest" 2>/dev/null)" || return 0
  tag="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<<"$json" | head -n1)"
  [[ "$tag" =~ $VERSION_RE ]] || return 0
  tar="$(grep -o '"browser_download_url": *"[^"]*"' <<<"$json" | sed 's/.*"\([^"]*\)"$/\1/' | grep -F "/agentbox-$tag.tar.gz" | grep -v '\.sig$' | head -n1)"
  sig="$(grep -o '"browser_download_url": *"[^"]*"' <<<"$json" | sed 's/.*"\([^"]*\)"$/\1/' | grep -F "/agentbox-$tag.tar.gz.sig" | head -n1)"
  [[ -n "$tar" && -n "$sig" ]] && echo "$tag $tar $sig"
}

# The CHANGELOG.md section of a version.
release_notes() {  # <changelog> <version>
  awk -v v="$2" '
    /^## / { if (on) exit; on = ($2 == v) }
    on { print }' "$1"
}

release_installed() {  # 0 if this copy is an installed version
  [[ "$(realpath -m -- "$SCRIPT_DIR")" == "$(realpath -m -- "$INSTALL_DIR/versions")"/* ]]
}

# release_switch <version>: make an installed version the current one.
release_switch() {
  local old=""
  [[ -L "$INSTALL_DIR/current" ]] && old="$(basename -- "$(readlink -- "$INSTALL_DIR/current")")"
  ln -sfn "versions/$1" "$INSTALL_DIR/current.tmp"
  mv -fT -- "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"
  if [[ -n "$old" && "$old" != "$1" ]]; then echo "$old" > "$INSTALL_DIR/previous"; fi
  release_sync_git_guard
  release_sync_completion
  echo "agentbox: now $1"
}

# git-guard installed as ~/.local/bin/git follows the current version.
release_sync_git_guard() {
  local guard="$HOME/.local/bin/git" new="$INSTALL_DIR/current/git-guard"
  if grep -qs 'agentbox git-guard' "$guard" && ! cmp -s "$guard" "$new"; then
    install -m 755 "$new" "$guard"
    echo "agentbox: updated git-guard in $guard"
  fi
}

# Tab completion in bash: a link into bash-completion's directory for your
# own completions, to the current version's file, so that it follows every
# switch. Made at the first switch with this code (install or update).
COMPLETION_LINK="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/agentbox"
release_sync_completion() {
  [[ -L "$COMPLETION_LINK" || ! -e "$COMPLETION_LINK" ]] || return 0  # your own file stays
  mkdir -p "$(dirname "$COMPLETION_LINK")"
  ln -sfn "$INSTALL_DIR/current/completions/agentbox.bash" "$COMPLETION_LINK"
}

release_update() {  # [--yes]
  local yes="" latest tag tar_url sig_url current tmp v
  [[ "${1:-}" == --yes ]] && yes=1
  if ! release_installed; then
    echo "error: this agentbox is a clone ($SCRIPT_DIR), not an installed version; update it with git pull" >&2
    return 2
  fi
  current="$(agentbox_version)"
  latest="$(release_latest)"
  if [[ -z "$latest" ]]; then
    echo "error: could not find the latest release of $RELEASE_REPO" >&2
    return 1
  fi
  read -r tag tar_url sig_url <<<"$latest"
  if [[ "$tag" == "$current" ]]; then
    echo "agentbox: $current is the latest release"
    return 0
  fi
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: tmp is local
  trap "rm -rf -- '$tmp'" RETURN
  curl -fsSL --max-time 120 -o "$tmp/release.tar.gz" "$tar_url" \
    && curl -fsSL --max-time 30 -o "$tmp/release.tar.gz.sig" "$sig_url" \
    || { echo "error: download of $tag failed" >&2; return 1; }
  if ! release_verify "$tmp/release.tar.gz" "$tmp/release.tar.gz.sig" "$SCRIPT_DIR/release/allowed_signers"; then
    echo "error: the signature of $tag does not verify against $SCRIPT_DIR/release/allowed_signers;" \
         "not installed. Report it: the release or the download may have been tampered with." >&2
    return 1
  fi
  mkdir "$tmp/x"
  tar -xzf "$tmp/release.tar.gz" -C "$tmp/x"
  v="$(agentbox_version "$tmp/x/agentbox-$tag")"
  if [[ "$v" != "$tag" ]]; then
    echo "error: the archive of $tag does not contain agentbox-$tag/ with that version" >&2
    return 1
  fi
  echo "agentbox: $current -> $tag (signature verified)"
  release_notes "$tmp/x/agentbox-$tag/CHANGELOG.md" "$tag" | sed 's/^/  /'
  if [[ -z "$yes" ]]; then
    local reply=""
    if [[ -t 0 ]]; then read -r -p "agentbox: install $tag? [y/N] " reply; fi
    [[ "$reply" == [yY]* ]] || { echo "agentbox: not installed"; return 0; }
  fi
  release_place "$tmp/x/agentbox-$tag" "$tag"
  release_switch "$tag"
}

# release_place <tree> <version>: copy a release into versions/, read-only.
release_place() {
  local dst="$INSTALL_DIR/versions/$2"
  mkdir -p "$INSTALL_DIR/versions"
  if [[ -e "$dst" ]]; then
    chmod -R u+w -- "$dst"
    rm -rf -- "${dst:?}"
  fi
  cp -R -- "$1" "$dst.tmp"
  rm -rf -- "${dst:?}.tmp/.git"
  chmod -R a-w -- "$dst.tmp"
  chmod u+w -- "$dst.tmp"
  mv -- "$dst.tmp" "$dst"
  chmod u-w -- "$dst"
}

release_rollback() {
  local prev
  prev="$(cat "$INSTALL_DIR/previous" 2>/dev/null)"
  if [[ ! "$prev" =~ $VERSION_RE && "$prev" != dev ]] || [[ ! -d "$INSTALL_DIR/versions/$prev" ]]; then
    echo "error: no previous version to go back to" >&2
    return 1
  fi
  release_switch "$prev"
}
