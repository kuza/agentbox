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
#   3. prefixes every skill with "<prefix>-" (directory and frontmatter name),
#      so vendored skills never shadow Claude Code's built-in ones (/code-review)
#      or each other across repos, and adds a note to each SKILL.md telling the
#      agent to use the prefixed names where the text uses upstream ones;
#   4. records what it installed in skills/.vendored-<owner>__<repo>, so a later
#      run removes skills that were dropped upstream or deselected, and how it
#      synced in vendor/<owner>__<repo>.sync, so check-updates.sh can spot a
#      newer upstream and repeat the sync.
#
# It never overwrites a skill it did not install itself (your own skills, or
# skills from another vendored repo with the same name): it stops instead.
#
# Environment:
#   SKILLS_ONLY      comma-separated skill names to install, as named upstream
#                    (without the prefix; default: all)
#   SKILLS_PREFIX    prefix for installed skill names (default: the repo owner,
#                    lowercased); set it empty to install names unchanged
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

owner="${slug%%__*}"
PREFIX="${SKILLS_PREFIX-$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')}"
if [[ -n "$PREFIX" && ! "$PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "error: SKILLS_PREFIX '$PREFIX' must be lowercase letters, digits and hyphens" >&2
  exit 1
fi
SEP="${PREFIX:+-}"

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

# Installed names carry the prefix; the manifest records installed names.
declare -A target_of=()
for n in "${!wanted[@]}"; do target_of[$n]="$PREFIX$SEP$n"; done

# Refuse to clobber skills this repo did not install.
for n in "${!wanted[@]}"; do
  t="${target_of[$n]}"
  if [[ -e "$SKILLS_DIR/$t" && -z "${previously[$t]:-}" ]]; then
    echo "error: $SKILLS_DIR/$t exists and was not installed from $slug; not overwriting" >&2
    exit 1
  fi
done

# The skills' text keeps upstream names ("call the Skill tool with "tdd"",
# "/code-review"). Rewriting them is guesswork: a bare name can also be
# something else, such as wayfinder's `research` ticket label. Instead each
# SKILL.md gets a note after its frontmatter mapping those names to the
# installed ones, and the agent applies it.
NOTE=""
if [[ -n "$PREFIX" ]]; then
  bt='`'
  sorted="$(printf '%s\n' "${!wanted[@]}" | sort)"
  example="$PREFIX-$(head -n1 <<<"$sorted")"
  names="$(sed "s/.*/$bt&$bt/" <<<"$sorted" | paste -sd, - | sed 's/,/, /g')"
  NOTE="> **Installed with a prefix.** Skills from this collection are installed as $bt$PREFIX-<name>$bt. When this text names one of them without the prefix ($names), invoke $bt$PREFIX-<name>$bt instead ($bt/$example$bt, the Skill tool with $bt$example$bt). Other skills and commands keep their names."
fi

prefix_skill() {  # <installed dir> <installed name>
  # Frontmatter name must match the directory name; the note follows the
  # frontmatter.
  awk -v name="$2" -v note="$NOTE" '
    NR == 1 && /^---[[:space:]]*$/ { fm = 1; print; next }
    fm && /^---[[:space:]]*$/ { fm = 0; print; print ""; print note; next }
    fm && /^name:/ { print "name: " name; next }
    { print }
  ' "$1/SKILL.md" > "$1/SKILL.md.tmp" && mv "$1/SKILL.md.tmp" "$1/SKILL.md"
}

# Remove skills that were installed before but are no longer wanted, including
# names from before a prefix change.
declare -A installing=()
for n in "${!wanted[@]}"; do installing[${target_of[$n]}]=1; done
for n in "${!previously[@]}"; do
  if [[ -z "${installing[$n]:-}" ]]; then
    rm -rf -- "${SKILLS_DIR:?}/$n"
    echo "removed  $n"
  fi
done

: > "$MANIFEST.tmp"
for n in $(printf '%s\n' "${!wanted[@]}" | sort); do
  t="${target_of[$n]}"
  rm -rf -- "${SKILLS_DIR:?}/$t"
  cp -R -- "${src_of[$n]}" "$SKILLS_DIR/$t"
  [[ -n "$PREFIX" ]] && prefix_skill "$SKILLS_DIR/$t" "$t"
  echo "$t" >> "$MANIFEST.tmp"
  echo "install  $t  (${src_of[$n]#"$VENDOR"/})"
done
mv "$MANIFEST.tmp" "$MANIFEST"

# What check-updates.sh needs to spot a newer upstream and repeat this sync.
# Plain KEY=VALUE lines, read as data.
{
  echo "URL=$URL"
  echo "COMMIT=$(git -C "$VENDOR" rev-parse HEAD)"
  echo "SKILLS_ONLY=${SKILLS_ONLY:-}"
  echo "SKILLS_PREFIX=$PREFIX"
  echo "AB_SKILLS_DIR=$SKILLS_DIR"
} > "$SCRIPT_DIR/vendor/$slug.sync"

echo "done: ${#wanted[@]} skills from $slug @ $commit -> $SKILLS_DIR"
echo "Review before use: git -C $VENDOR log --oneline -5 ; diff the skills/ directory"
