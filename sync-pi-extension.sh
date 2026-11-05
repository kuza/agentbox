#!/usr/bin/env bash
# sync-pi-extension.sh: install a pi extension from a git repository into
# agentbox's pi extensions directory, on the HOST (the box has no GitHub or
# npm access).
#
# Usage:
#   ./sync-pi-extension.sh <name> <git-url> [ref]
#   ./sync-pi-extension.sh --remove <name>
#
# Usually run by run.sh for the sources in AB_PI_EXTENSIONS
# (pi-extensions.d/<name>.conf), and by check-updates.sh for an update you
# accept.
#
# What it does:
#   1. It makes a new clone of the repository in a scratch directory, with
#      hooks off. It checks out <ref>, or the default branch of the remote.
#      It keeps no clone.
#   2. It checks that the repository is a pi extension: a package.json with
#      "pi.extensions", or an index.ts or index.js at the top. It refuses
#      symlinks.
#   3. If package.json has "dependencies", it installs them from
#      package-lock.json with npm ci. It omits the dev and peer dependencies
#      (pi gives extensions its own packages). It runs no install scripts,
#      makes no bin links, and ignores the .npmrc of the repository. It
#      refuses a package that is not from the npm registry: npm runs the
#      scripts of a git dependency on the host, also with --ignore-scripts.
#   4. It copies the result next to the extensions directory, then moves it
#      to <pi-extensions>/<name> in one step. It records the URL, the
#      commit, the pin and the source mark in
#      <AB_HOME>/pi-extensions.sources/<name>. check-updates.sh and run.sh
#      read the record as data (KEY=VALUE lines).
#
# It never replaces a directory that it did not install. An extension that
# you copied there yourself stays, and the sync stops.
#
# Environment:
#   AB_PI_EXTENSIONS_PIN     the REF of the source, recorded as a pin (set
#                            by run.sh). A pinned source gets no update
#                            offers.
#   AB_PI_EXTENSIONS_SOURCE  1 when run.sh installs a source of
#                            AB_PI_EXTENSIONS (set by run.sh). The start
#                            removes only such extensions when you disable
#                            them, not an extension that you installed with
#                            this script yourself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/git-source.sh
source "$SCRIPT_DIR/lib/git-source.sh"
EXT_DIR="$USER_PI_EXTENSIONS"
REC_DIR="$USER_PI_EXTENSIONS_RECORDS"

if [[ "${1:-}" == --remove ]]; then
  name="${2:?usage: $0 --remove <name>}"
  [[ "$name" =~ $AB_NAME_RE ]] || { echo "error: invalid name '$name'" >&2; exit 2; }
  if [[ -f "$REC_DIR/$name" ]]; then
    rm -rf -- "${EXT_DIR:?}/$name"
    rm -f -- "$REC_DIR/$name"
    echo "removed  pi extension $name"
  fi
  exit 0
fi

name="${1:?usage: $0 <name> <git-url> [ref]}"
URL="${2:?usage: $0 <name> <git-url> [ref]}"
REF="${3:-}"
[[ "$name" =~ $AB_NAME_RE ]] || { echo "error: invalid name '$name' (a-z, 0-9 and -)" >&2; exit 2; }

if [[ -e "$EXT_DIR/$name" && ! -f "$REC_DIR/$name" ]]; then
  echo "error: $EXT_DIR/$name exists and was not installed by agentbox; not replacing it" >&2
  exit 1
fi

# --- 1. fetch ---------------------------------------------------------------
SCRATCH="$(mktemp -d)"
STAGE=""
trap 'rm -rf -- "${SCRATCH:?}" ${STAGE:+"$STAGE"}' EXIT
SRC="$SCRATCH/repo"
commit="$(git_source_clone "$URL" "$SRC" "$REF")"
rm -rf -- "${SRC:?}/.git"

# --- 2. check ---------------------------------------------------------------
links="$(find "$SRC" -type l)"
if [[ -n "$links" ]]; then
  echo "error: $URL contains symlinks, which are not installed:" >&2
  printf '%s\n' "${links//"$SRC"\//}" | sed 's/^/  /' >&2
  exit 1
fi
# With Node.js, read as JSON; without, as text: the host needs Node.js only
# for an extension with dependencies.
has_manifest=""
if [[ -f "$SRC/package.json" ]]; then
  if command -v node >/dev/null; then
    node -e 'const p = require(process.argv[1]); process.exit(p.pi && Array.isArray(p.pi.extensions) && p.pi.extensions.length ? 0 : 1)' \
      "$SRC/package.json" 2>/dev/null && has_manifest=1
  elif grep -q '"pi"' "$SRC/package.json" && grep -Eq '"extensions"[[:space:]]*:' "$SRC/package.json"; then
    has_manifest=1
  fi
fi
if [[ -z "$has_manifest" && ! -f "$SRC/index.ts" && ! -f "$SRC/index.js" ]]; then
  echo "error: $URL is not a pi extension: no package.json with \"pi.extensions\", no index.ts or index.js" >&2
  exit 1
fi

# --- 3. dependencies --------------------------------------------------------
deps=0
if [[ -f "$SRC/package.json" ]] && grep -Eq '"dependencies"[[:space:]]*:' "$SRC/package.json" \
   && ! grep -Eq '"dependencies"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}' "$SRC/package.json"; then
  deps=1
  if command -v node >/dev/null; then
    deps="$(node -e 'const p = require(process.argv[1]); console.log(Object.keys(p.dependencies || {}).length)' "$SRC/package.json" 2>/dev/null)" \
      || { echo "error: $URL: package.json cannot be read" >&2; exit 1; }
  fi
fi
if (( deps > 0 )); then
  if [[ ! -f "$SRC/package-lock.json" ]]; then
    echo "error: $URL has dependencies but no package-lock.json: the packages would not be pinned" >&2
    exit 1
  fi
  command -v npm >/dev/null || { echo "error: $URL has dependencies; installing them needs npm on the host" >&2; exit 1; }
  # npm ci --ignore-scripts still runs the scripts of a git dependency (npm
  # prepares it with "npm install"), on the host. Thus every package must
  # come from the npm registry: no git, file, link or other URL.
  if ! why="$(node -e '
      const l = require(process.argv[1]);
      if (!(l.lockfileVersion >= 2) || !l.packages) { console.log("lockfileVersion 2 or newer is needed"); process.exit(1); }
      for (const [p, e] of Object.entries(l.packages)) {
        if (p === "" || e.inBundle) continue;
        if (e.link) { console.log(p + " is a link"); process.exit(1); }
        if (typeof e.resolved !== "string" || !e.resolved.startsWith("https://registry.npmjs.org/")) {
          console.log(p + " is not from the npm registry: " + (e.resolved || "no resolved URL")); process.exit(1);
        }
      }' "$SRC/package-lock.json" 2>&1)"; then
    echo "error: $URL: package-lock.json: $why" >&2
    exit 1
  fi
  # Its own npm settings (registry, scripts) do not apply.
  rm -f -- "$SRC/.npmrc"
  echo "agentbox: installing the dependencies of pi extension $name (npm ci)" >&2
  (cd "$SRC" && npm ci --omit=dev --omit=peer --ignore-scripts --no-bin-links --no-audit --no-fund >&2)
fi

# --- 4. install -------------------------------------------------------------
# Copied next to the mounted directory, on the same file system, under a
# name of its own, then moved into place: a session that starts meanwhile
# does not see a part of it.
mkdir -p "$EXT_DIR" "$REC_DIR"
STAGE="$(mktemp -d "$AB_HOME_DIR/.pi-extension-$name.XXXXXX")"
cp -R -- "$SRC/." "$STAGE/"
chmod 755 "$STAGE"
# The old one goes aside first, then the new one moves in: mv -T fails
# rather than put the stage inside a directory that another start made.
OLD=""
if [[ -e "$EXT_DIR/$name" ]]; then
  OLD="$(mktemp -d "$AB_HOME_DIR/.pi-extension-$name.old.XXXXXX")"
  mv -T -- "$EXT_DIR/$name" "$OLD"
fi
if ! mv -T -- "$STAGE" "$EXT_DIR/$name"; then
  [[ -z "$OLD" ]] || mv -T -- "$OLD" "$EXT_DIR/$name" || true
  echo "error: could not move pi extension $name into place" >&2
  exit 1
fi
STAGE=""
[[ -z "$OLD" ]] || rm -rf -- "$OLD"
{
  echo "URL=$URL"
  echo "COMMIT=$commit"
  echo "REF=${AB_PI_EXTENSIONS_PIN:-}"
  echo "SOURCE=${AB_PI_EXTENSIONS_SOURCE:-}"
} > "$REC_DIR/$name.tmp"
mv -f -- "$REC_DIR/$name.tmp" "$REC_DIR/$name"

echo "done: pi extension $name @ ${commit:0:7} -> $EXT_DIR/$name"
echo "Read what you installed before you use it: pi runs it in the box."
