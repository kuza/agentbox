#!/usr/bin/env bash
# sync-skills.sh: vendor a git repository of agent skills into agentbox's
# personal skills directory, on the HOST (the box itself has no GitHub access).
#
# Usage:
#   ./sync-skills.sh <git-url> [ref]
#   ./sync-skills.sh --remove <git-url>     remove what it installed from there
#
# Examples:
#   ./sync-skills.sh https://github.com/mattpocock/skills
#   ./sync-skills.sh https://github.com/mattpocock/skills 3f2c1ab      # pin a commit
#   SKILLS_ONLY=tdd,grill-me,code-review ./sync-skills.sh https://github.com/mattpocock/skills
#
# Usually run by run.sh for the sources in AB_SKILLS (skills.d/<name>.conf);
# by hand for a one-off repository.
#
# What it does:
#   1. clones the repo afresh into a scratch directory, hooks off, and checks
#      out <ref> (default: the remote's default branch). No clone is kept: a
#      kept clone lives where a session that mounts agentbox can write, and a
#      hook or config planted in it would run on the host on the next sync;
#   2. finds every directory containing a SKILL.md, at any depth, and copies it
#      flat to skills/<skill-name>/, because Claude Code only looks one level
#      deep (~/.claude/skills/<name>/SKILL.md);
#   3. prefixes every skill with "<prefix>-" (directory and frontmatter name),
#      so vendored skills never shadow Claude Code's built-in ones (/code-review)
#      or each other across repos, and adds a note to each SKILL.md telling the
#      agent to use the prefixed names where the text uses upstream ones;
#   4. records the sync in skills/.sources/<owner>__<repo>: how it synced
#      (URL, commit, selection, prefix, source, pin) and one SKILL= line per
#      installed skill. A later run removes skills that were dropped upstream
#      or deselected; check-updates.sh spots a newer upstream; run.sh tells
#      whether a source changed. Plain KEY=VALUE lines, read as data.
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
#   SKILLS_SOURCE    name of the skills.d source this sync is for (set by
#                    run.sh); recorded so run.sh can remove a disabled source
#   SKILLS_PIN       the source's REF, recorded as a pin (set by run.sh); a
#                    pinned source gets no update offers. A [ref] argument
#                    alone does not pin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVE=""
if [[ "${1:-}" == --remove ]]; then REMOVE=1; shift; fi
URL="${1:?usage: $0 [--remove] <git-url> [ref]}"
REF="${2:-}"
SKILLS_DIR="${AB_SKILLS_DIR:-$SCRIPT_DIR/skills}"

# owner__repo from https://github.com/owner/repo(.git) or git@github.com:owner/repo(.git)
slug="$(printf '%s' "$URL" | sed -E 's#(\.git)?/*$##; s#^.*[:/]([^/:]+)/([^/]+)$#\1__\2#')"
STATE="$SKILLS_DIR/.sources/$slug"

installed_skills() {  # names this repository installed, from its state file
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^SKILL=//p' "$STATE" | while IFS= read -r n; do
    [[ -n "$n" && "$n" != */* && "$n" != .* ]] && printf '%s\n' "$n"
  done
}

if [[ -n "$REMOVE" ]]; then
  for n in $(installed_skills); do
    rm -rf -- "${SKILLS_DIR:?}/$n"
    echo "removed  $n"
  done
  rm -f -- "$STATE"
  echo "done: removed the skills from $slug"
  exit 0
fi

owner="${slug%%__*}"
PREFIX="${SKILLS_PREFIX-$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')}"
if [[ -n "$PREFIX" && ! "$PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "error: SKILLS_PREFIX '$PREFIX' must be lowercase letters, digits and hyphens" >&2
  exit 1
fi
SEP="${PREFIX:+-}"

mkdir -p "$SKILLS_DIR/.sources"

# --- 1. fetch ---------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf -- "${SCRATCH:?}"' EXIT
VENDOR="$SCRATCH/repo"
git -c core.hooksPath=/dev/null clone --quiet "$URL" "$VENDOR"
if [[ -z "$REF" ]]; then
  REF="origin/$(git -C "$VENDOR" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')"
fi
git -C "$VENDOR" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach "$REF"
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
for n in $(installed_skills); do previously[$n]=1; done

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

installed=()
for n in $(printf '%s\n' "${!wanted[@]}" | sort); do
  t="${target_of[$n]}"
  rm -rf -- "${SKILLS_DIR:?}/$t"
  cp -R -- "${src_of[$n]}" "$SKILLS_DIR/$t"
  [[ -n "$PREFIX" ]] && prefix_skill "$SKILLS_DIR/$t" "$t"
  installed+=("$t")
  echo "install  $t  (${src_of[$n]#"$VENDOR"/})"
done

{
  echo "URL=$URL"
  echo "COMMIT=$(git -C "$VENDOR" rev-parse HEAD)"
  echo "SKILLS_ONLY=${SKILLS_ONLY:-}"
  echo "SKILLS_PREFIX=$PREFIX"
  echo "SOURCE=${SKILLS_SOURCE:-}"
  echo "REF=${SKILLS_PIN:-}"
  printf 'SKILL=%s\n' "${installed[@]}"
} > "$STATE.tmp"
mv -f "$STATE.tmp" "$STATE"

echo "done: ${#wanted[@]} skills from $slug @ $commit -> $SKILLS_DIR"
echo "Read what you installed before you use it: $SKILLS_DIR/${PREFIX:-<name>}${SEP}*"
