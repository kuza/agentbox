#!/usr/bin/env bash
# release.sh: publish a release, on the maintainer's HOST (README, Releases).
#
#   ./release.sh vX.Y.Z
#
# Checks first, and stops at the first problem:
#   - the version is vX.Y.Z, new, and has a "## vX.Y.Z" section in CHANGELOG.md;
#   - you are on main, the tree is clean, and main is what origin has;
#   - the signing key's public half is in release/allowed_signers;
#   - tests/run.sh passes.
# Then: a signed tag, the archive (git archive, so only what git tracks, with
# the version in VERSION), its SSH signature, a check of that signature
# against allowed_signers as `agentbox update` will do it, and, after you
# confirm, the tag pushed and the GitHub release created with gh.
#
# Environment:
#   AB_RELEASE_KEY  the SSH key that signs, its private or its .pub file
#                   (default: git config user.signingkey, else
#                   ~/.ssh/agentbox-release). With the key in ssh-agent
#                   (ssh-add -t 1h ~/.ssh/agentbox-release) the agent signs
#                   and the passphrase is asked once; without, ssh-keygen and
#                   git ask for it at each signature.
#   AB_RELEASE_YES  1: do not ask before pushing and publishing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"
cd "$SCRIPT_DIR"

die() { echo "error: $*" >&2; exit 1; }

v="${1:-}"
[[ "$v" =~ $VERSION_RE ]] || die "usage: $0 vX.Y.Z"
key="${AB_RELEASE_KEY:-$(git config user.signingkey || true)}"
key="${key:-$HOME/.ssh/agentbox-release}"
key="${key/#\~/$HOME}"
# The public half names the key; the agent signs with it if it holds the key,
# else the private file does (asking for its passphrase).
if [[ "$key" == *.pub ]]; then pubfile="$key"; private="${key%.pub}"; else pubfile="$key.pub"; private="$key"; fi
[[ -f "$pubfile" ]] || die "no public key at $pubfile (AB_RELEASE_KEY)"
pub="$(cat "$pubfile")"
blob="$(awk '{ print $2 }' <<<"$pub")"
if ssh-add -L 2>/dev/null | awk '{ print $2 }' | grep -qxF -- "$blob"; then
  signer="$pubfile"
  echo "release: signing with ssh-agent"
elif [[ -f "$private" ]]; then
  signer="$private"
  echo "release: signing with $private (ssh-add it to type the passphrase once)"
else
  die "the key of $pubfile is neither in ssh-agent nor at $private"
fi

[[ "$(git branch --show-current)" == main ]] || die "not on main"
[[ -z "$(git status --porcelain)" ]] || die "the working tree is not clean"
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main differs from origin/main; push or pull first"
git rev-parse -q --verify "refs/tags/$v" >/dev/null && die "tag $v exists"
[[ -n "$(release_notes CHANGELOG.md "$v")" ]] || die "CHANGELOG.md has no '## $v' section"
grep -v '^#' release/allowed_signers | grep -qF -- "$blob" \
  || die "the key of $pubfile is not in release/allowed_signers; add it in a commit first"
echo "release: running the tests..."
./tests/run.sh > /dev/null || die "tests/run.sh fails"

dist="$SCRIPT_DIR/dist"
mkdir -p "$dist"
tarball="$dist/agentbox-$v.tar.gz"
git -c gpg.format=ssh -c user.signingkey="$signer" tag -s "$v" -m "agentbox $v"
git archive --prefix="agentbox-$v/" -o "$tarball" "$v"
rm -f -- "$tarball.sig"
ssh-keygen -q -Y sign -f "$signer" -n "$RELEASE_NAMESPACE" "$tarball"
git show "$v:release/allowed_signers" > "$dist/allowed_signers"
release_verify "$tarball" "$tarball.sig" "$dist/allowed_signers" \
  || die "the signature does not verify against allowed_signers of $v"
[[ "$(tar -xzOf "$tarball" "agentbox-$v/VERSION")" == "$v" ]] || die "VERSION in the archive is not $v"
release_notes CHANGELOG.md "$v" > "$dist/notes-$v.md"
echo "release: $tarball, signed and verified"

if [[ "${AB_RELEASE_YES:-}" != 1 ]]; then
  reply=""
  read -r -p "release: push tag $v and publish the GitHub release? [y/N] " reply || true
  [[ "$reply" == [yY]* ]] || { echo "release: stopped; delete the tag with: git tag -d $v"; exit 0; }
fi
git push origin "$v"
gh release create "$v" "$tarball" "$tarball.sig" --title "agentbox $v" --notes-file "$dist/notes-$v.md"
echo "release: $v published"
