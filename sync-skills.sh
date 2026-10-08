#!/usr/bin/env bash
# sync-skills.sh: vendor a git repository of agent skills into agentbox's
# personal skills directory, on the HOST (the box itself has no GitHub access).
#
# Usage:
#   ./sync-skills.sh <git-url> [ref]
#
# Examples:
#   ./sync-skills.sh https://github.com/mattpocock/skills
#   ./sync-skills.sh https://github.com/mattpocock/skills 3f2c1ab      # pin a commit
#   SKILLS_ONLY=tdd,grill-me,code-review ./sync-skills.sh https://github.com/mattpocock/skills
#
# What it does:
#   1. clones/updates the repo into vendor/<owner>__<repo>/ and checks out <ref>
#      (default: the remote's default branch);
#   2. finds every directory containing a SKILL.md, at any depth, and copies it
#      flat to skills/<skill-name>/, because Claude Code only looks one level
#      deep (~/.claude/skills/<name>/SKILL.md);
#   3. records what it installed in skills/.vendored-<owner>__<repo>, so a later
#      run removes skills that were dropped upstream or deselected.
#
# It never overwrites a skill it did not install itself (your own skills, or
# skills from another vendored repo with the same name): it stops instead.
#
# Environment:
#   SKILLS_ONLY      comma-separated skill names to install (default: all)
#   AB_SKILLS_DIR    target directory (default: <script dir>/skills), same
#                    variable run.sh uses
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${1:?usage: $0 <git-url> [ref]}"
REF="${2:-}"
SKILLS_DIR="${AB_SKILLS_DIR:-$SCRIPT_DIR/skills}"

# owner__repo from https://github.com/owner/repo(.git) or git@github.com:owner/repo(.git)
slug="$(printf '%s' "$URL" | sed -E 's#(\.git)?/*$##; s#^.*[:/]([^/:]+)/([^/]+)$#\1__\2#')"
VENDOR="$SCRIPT_DIR/vendor/$slug"
MANIFEST="$SKILLS_DIR/.vendored-$slug"

mkdir -p "$SCRIPT_DIR/vendor" "$SKILLS_DIR"

# --- 1. fetch ---------------------------------------------------------------
if [[ -d "$VENDOR/.git" ]]; then
  git -C "$VENDOR" fetch --quiet --tags origin
else
  git clone --quiet "$URL" "$VENDOR"
fi
if [[ -z "$REF" ]]; then
  REF="origin/$(git -C "$VENDOR" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')"
fi
git -C "$VENDOR" -c advice.detachedHead=false checkout --quiet --detach "$REF"
commit="$(git -C "$VENDOR" rev-parse --short HEAD)"

# --- 2. collect skills ------------------------------------------------------
declare -A src_of=()
while IFS= read -r -d '' f; do
  dir="$(dirname "$f")"
  name="$(basename "$dir")"
  if [[ -n "${src_of[$name]:-}" ]]; then
    echo "error: skill name '$name' appears twice in $slug:" >&2
    echo "  ${src_of[$name]#"$VENDOR"/}" >&2
    echo "  ${dir#"$VENDOR"/}" >&2
    exit 1
  fi
  src_of[$name]="$dir"
done < <(find "$VENDOR" -name SKILL.md -not -path '*/.git/*' -not -path '*/node_modules/*' -print0)

if (( ${#src_of[@]} == 0 )); then
  echo "error: no SKILL.md found in $URL" >&2
  exit 1
fi

# Optional selection
declare -A wanted=()
if [[ -n "${SKILLS_ONLY:-}" ]]; then
  IFS=',' read -r -a only <<<"$SKILLS_ONLY"
  for n in "${only[@]}"; do
    n="${n// /}"
    [[ -n "${src_of[$n]:-}" ]] || { echo "error: '$n' is not a skill in $slug" >&2; exit 1; }
    wanted[$n]=1
  done
else
  for n in "${!src_of[@]}"; do wanted[$n]=1; done
fi

# --- 3. install -------------------------------------------------------------
declare -A previously=()
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r n; do [[ -n "$n" ]] && previously[$n]=1; done < "$MANIFEST"
fi

# Refuse to clobber skills this repo did not install.
for n in "${!wanted[@]}"; do
  if [[ -e "$SKILLS_DIR/$n" && -z "${previously[$n]:-}" ]]; then
    echo "error: $SKILLS_DIR/$n exists and was not installed from $slug; not overwriting" >&2
    exit 1
  fi
done

# Remove skills that were installed before but are no longer wanted.
for n in "${!previously[@]}"; do
  if [[ -z "${wanted[$n]:-}" ]]; then
    rm -rf -- "${SKILLS_DIR:?}/$n"
    echo "removed  $n"
  fi
done

: > "$MANIFEST.tmp"
for n in $(printf '%s\n' "${!wanted[@]}" | sort); do
  rm -rf -- "${SKILLS_DIR:?}/$n"
  cp -R -- "${src_of[$n]}" "$SKILLS_DIR/$n"
  echo "$n" >> "$MANIFEST.tmp"
  echo "install  $n  (${src_of[$n]#"$VENDOR"/})"
done
mv "$MANIFEST.tmp" "$MANIFEST"

echo "done: ${#wanted[@]} skills from $slug @ $commit -> $SKILLS_DIR"
echo "Review before use: git -C $VENDOR log --oneline -5 ; diff the skills/ directory"
