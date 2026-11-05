# Clones a git repository of skills or of a pi extension, on the host, for
# sync-skills.sh and sync-pi-extension.sh.
#
# The clone is new, in a directory of the caller, with hooks off, and git
# runs outside any repository, so no local git config or hooks apply. A URL
# or a ref that starts with "-" is refused: git would read it as an option.

# Clones <url> into <dir> and checks out <ref>: a branch, a tag or a commit.
# Without <ref>, the default branch of the remote. Prints the commit.
git_source_clone() {  # <url> <dir> [ref]
  local url="$1" dir="$2" ref="${3:-}" commit
  if [[ "$url" == -* || "$ref" == -* ]]; then
    echo "error: a URL or REF must not start with '-': '$url' '$ref'" >&2
    return 1
  fi
  # A local path relative to here keeps working after the cd.
  [[ -e "$url" ]] && url="$(realpath -- "$url")"
  (cd / && git -c core.hooksPath=/dev/null clone --quiet -- "$url" "$dir") || return 1
  if [[ -z "$ref" ]]; then
    ref="origin/$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')"
  fi
  # A branch is only origin/<branch> in a new clone: try that first, then
  # the ref as it is (a tag or a commit).
  commit="$(git -C "$dir" rev-parse --verify --quiet "origin/$ref^{commit}")" \
    || commit="$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}")" \
    || { echo "error: $url has no branch, tag or commit '$ref'" >&2; return 1; }
  git -C "$dir" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach "$commit" \
    || return 1
  printf '%s\n' "$commit"
}

# A SUBDIR of a skill source as one form, for sync-skills.sh and the record
# comparison in lib/skills.sh: without a trailing "/", and empty for the
# whole repository ("" or "."). 1 for a value that is not a plain path, or
# that names nothing ("/").
git_source_subdir() {  # <value> [its name, for messages]: prints the normal form
  local d="$1" label="${2:-SUBDIR}"
  [[ -z "$d" ]] && return 0
  if [[ ! "$d" =~ ^[A-Za-z0-9._/-]+$ || "$d" =~ ^/+$ ]]; then
    echo "error: $label '$d' must be a plain path in the repository" >&2
    return 1
  fi
  # All trailing slashes: the result is the same when it runs on it again.
  while [[ "$d" == */ ]]; do d="${d%/}"; done
  [[ "$d" == . ]] && return 0
  printf '%s\n' "$d"
}
