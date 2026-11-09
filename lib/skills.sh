# Personal skills: one subdirectory per skill, each with a SKILL.md.
# Mounted read-only over the agent's skills directory so the agent cannot
# rewrite its own skills (they would otherwise persist in its home volume
# across sessions and repos). Project skills in <repo>/.claude/skills need
# nothing: the repo is mounted.
#
# Skill sources: skills.d/<name>.toml (shared, in git) or
# <AB_HOME>/skills.local.d/<name>.toml (yours; wins over skills.d/).
# AB_SKILLS in config.env lists the enabled ones. A source is a git
# repository of skills, installed into the skills directory by
# sync-skills.sh. Its file is TOML data, never run, read by toml_load
# (lib/toml.sh, kind skill-source):
#   url      git URL of the repository (required)
#   only     the skills to install, as named there, a list (default: all)
#   subdir   directory in the repository to look for skills in (default:
#            all of it)
#   prefix   prefix for the installed names (default: the repository owner;
#            "": none)
#   ref      branch, tag or commit to pin to (default: the default branch,
#            with updates offered by check-updates.sh)
#
# skills_sources installs an enabled source that is missing, re-syncs one
# whose file changed (at the installed commit, so a changed "only" does not
# also upgrade it), and removes the skills of a source that was disabled.
# It compares with <skills>/.sources/<owner>__<repo>, the record
# sync-skills.sh keeps; skills synced by hand, without a source, are left
# alone.
#
# Needs lib/paths.sh, lib/config.sh (conf_find, ab_warn), lib/toml.sh,
# lib/convert.sh (convert_toml_find, convert_why_missing) and, for
# skills_sources, lib/git-source.sh (git_source_subdir).

SKILLS_SOURCE_DIRS=("$USER_SKILLS_SOURCES_DIR" "$SCRIPT_DIR/skills.d")

# Sets SKILLS_DIR and GRAPHIFY_PI, and moves state from where older versions
# kept it. Runs before check-updates.sh, which reads the records.
skills_init() {
  SKILLS_DIR="${AB_SKILLS_DIR:-$USER_SKILLS_DIR}"
  GRAPHIFY_PI="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/graphify-pi"
  skills_migrate_state
}

# Older versions kept a record per repository in vendor/<owner>__<repo>.sync
# and the installed names in <skills>/.vendored-<owner>__<repo>; now both are
# one file, <skills>/.sources/<owner>__<repo>. pi's graphify variant moved
# from vendor/graphify to the cache. No network, nothing is re-synced.
skills_migrate_state() {
  local f slug dir manifest state
  for f in "$SCRIPT_DIR"/vendor/*.sync "$SKILLS_DIR"/.vendored-*; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == *.sync ]]; then
      slug="$(basename "$f" .sync)"
      dir="$(source_value "$f" AB_SKILLS_DIR)"
      dir="${dir:-$SKILLS_DIR}"
    else
      slug="$(basename "$f")"; slug="${slug#.vendored-}"
      dir="$SKILLS_DIR"
    fi
    manifest="$dir/.vendored-$slug"
    state="$dir/.sources/$slug"
    mkdir -p "$dir/.sources"
    {
      if [[ "$f" == *.sync ]]; then
        grep -E '^(URL|COMMIT|SKILLS_ONLY|SKILLS_PREFIX|SOURCE|REF)=' "$f" || true
      fi
      if [[ -f "$manifest" ]]; then sed '/^$/d; s/^/SKILL=/' "$manifest"; fi
    } > "$state.tmp"
    mv -f "$state.tmp" "$state"
    rm -f -- "$manifest"
    if [[ "$f" == *.sync ]]; then rm -f -- "$f"; fi
    echo "agentbox: moved the record of $slug to $state" >&2
  done
  if [[ -d "$SCRIPT_DIR/vendor/graphify" ]]; then
    rm -rf -- "${SCRIPT_DIR:?}/vendor/graphify"
  fi
  rmdir "$SCRIPT_DIR/vendor" 2>/dev/null || true
}

source_value() {  # <file> <key>: value of KEY=VALUE, empty if missing
  sed -n "s/^$2=//p" "$1" | tail -n1
}

# Reads the source <name> for <setting> (AB_SKILLS, AB_PI_EXTENSIONS).
# The name must be valid. toml_load reads the first <dir>/<name>.toml into
# the arrays named <values> and <lines>, and the url must not be empty.
# SOURCE_FILE gets the path of the file. Otherwise it says why and returns
# 2, and the caller stops the start.
source_load() {  # <setting> <what> <kind> <name> <values> <lines> <dirs: yours, then shared>
  local _sl_setting="$1" _sl_what="$2" _sl_kind="$3" _sl_name="$4" rc=0
  local -n _sl_values="$5" _sl_lines="$6"
  shift 6
  if [[ ! "$_sl_name" =~ $AB_NAME_RE ]]; then
    echo "error: $_sl_setting: invalid source name '$_sl_name'" >&2
    return 2
  fi
  SOURCE_FILE="$(convert_toml_find "$_sl_name" "$@")" || rc=$?
  if (( rc == 3 )); then
    echo "error: $_sl_setting: $SOURCE_FILE was not converted to TOML (see the warning above). agentbox does not use the shared $_sl_what of that name in its place." >&2
    return 2
  fi
  if (( rc )); then
    echo "error: $_sl_setting: no $_sl_what '$_sl_name' (looked for $1/$_sl_name.toml and $(basename "$2")/$_sl_name.toml)" >&2
    convert_why_missing "$1/$_sl_name.conf"
    return 2
  fi
  toml_load "$_sl_kind" "$SOURCE_FILE" "${!_sl_values}" "${!_sl_lines}" || return 2
  if [[ -z "${_sl_values[url]}" ]]; then
    echo "$SOURCE_FILE:${_sl_lines[url]%% *}: 'url' is empty" >&2
    return 2
  fi
}

# The repository of skill source <name> as skills_sources sees it
# (repo_slug: no ".git", no trailing "/"). Empty when there is no such
# source or its file is bad.
skill_source_slug() {  # <name>
  local file
  local -A desc=()
  if file="$(convert_toml_find "$1" "${SKILLS_SOURCE_DIRS[@]}")" && toml_load skill-source "$file" desc 2>/dev/null; then
    repo_slug "${desc[url]}"
  fi
}

repo_slug() {  # <url>: owner__repo, as sync-skills.sh computes it
  printf '%s' "$1" | sed -E 's#(\.git)?/*$##; s#^.*[:/]([^/:]+)/([^/]+)$#\1__\2#'
}

sorted_list() {  # <list, separated by commas or spaces>: sorted, comma-separated
  printf '%s' "$1" | tr ', ' '\n\n' | sed '/^$/d' | sort | paste -sd, -
}

skills_sources() {
  local list="${AB_SKILLS:-}" name url only subdir prefix ref slug sync want have at f src
  local -A enabled_url=() source_of_slug=() desc=() desc_lines=()
  for name in ${list//,/ }; do
    source_load AB_SKILLS "skill source" skill-source "$name" desc desc_lines "${SKILLS_SOURCE_DIRS[@]}" || exit 2
    url="${desc[url]}"
    # The same form as the record (SKILLS_ONLY) and as v0.1.x.
    only="$(sorted_list "${desc[only]:-}")"
    subdir="$(git_source_subdir "${desc[subdir]:-}" "$SOURCE_FILE: subdir")" || exit 2
    slug="$(repo_slug "$url")"
    # The sync record is per repository: two sources of one repository
    # would overwrite each other's skills on every start.
    if [[ -n "${source_of_slug[$slug]:-}" ]]; then
      echo "error: AB_SKILLS: sources '${source_of_slug[$slug]}' and '$name' both use $url;" \
           "make them one source (its \"only\" lists the skills of both)" >&2
      exit 2
    fi
    source_of_slug[$slug]="$name"
    if [[ -n "${desc[prefix]+x}" ]]; then
      prefix="${desc[prefix]}"
    else
      prefix="$(printf '%s' "${slug%%__*}" | tr '[:upper:]' '[:lower:]')"
    fi
    ref="${desc[ref]:-}"
    enabled_url[$name]="$url"

    sync="$SKILLS_DIR/.sources/$slug"
    want="$url|$only|$prefix|$name|$ref|$subdir"
    have=""
    if [[ -f "$sync" ]]; then
      have="$(source_value "$sync" URL)|$(sorted_list "$(source_value "$sync" SKILLS_ONLY)")|$(source_value "$sync" SKILLS_PREFIX)|$(source_value "$sync" SOURCE)|$(source_value "$sync" REF)|$(source_value "$sync" SKILLS_SUBDIR)"
    fi
    [[ "$want" == "$have" ]] && continue

    # Pinned: that ref. Changed settings of an installed source: the installed
    # commit, so only the selection changes. New: the default branch.
    at="$ref"
    if [[ -z "$at" && -f "$sync" && "$(source_value "$sync" URL)" == "$url" ]]; then
      at="$(source_value "$sync" COMMIT)"
    fi
    echo "agentbox: syncing skills from '$name' ($url)" >&2
    if ! SKILLS_ONLY="$only" SKILLS_PREFIX="$prefix" SKILLS_SUBDIR="$subdir" AB_SKILLS_DIR="$SKILLS_DIR" \
         SKILLS_SOURCE="$name" SKILLS_PIN="$ref" \
         "$SCRIPT_DIR/sync-skills.sh" "$url" ${at:+"$at"} >&2; then
      ab_warn "could not sync skills from '$name'; continuing with what is installed"
    fi
  done

  # Sources installed by run.sh that are disabled now, or whose URL changed.
  for f in "$SKILLS_DIR"/.sources/*; do
    [[ -f "$f" ]] || continue
    src="$(source_value "$f" SOURCE)"
    [[ -n "$src" ]] || continue
    url="$(source_value "$f" URL)"
    [[ "${enabled_url[$src]:-}" == "$url" ]] && continue
    echo "agentbox: removing skills of disabled source '$src' ($url)" >&2
    AB_SKILLS_DIR="$SKILLS_DIR" "$SCRIPT_DIR/sync-skills.sh" --remove "$url" >&2 \
      || ab_warn "could not remove skills from '$src'"
  done
}

skills_prepare() {
  local image_id graphify_tmp
  skills_sources

  # graphify skill, taken from the image so it always matches the graphify CLI
  # there: `graphify install` into a scratch home, then
  #   <skills>/graphify               Claude Code's variant (shared skills dir)
  #   <cache>/agentbox/graphify-pi/graphify  pi's variant, mounted over the shared one
  # Refreshed when the image changes (its ID is recorded next to the skill), so a
  # rebuild with a new GRAPHIFY_VERSION brings the matching skill. A
  # <skills>/graphify that agentbox did not install is left alone.
  GRAPHIFY_STAMP="$SKILLS_DIR/graphify/.agentbox-image"
  agentbox_image_id; image_id="$AGENTBOX_IMAGE_ID"
  if [[ -e "$SKILLS_DIR/graphify" && ! -f "$GRAPHIFY_STAMP" ]]; then
    ab_warn "$SKILLS_DIR/graphify was not installed by agentbox; not updating it"
  elif [[ "$(cat "$GRAPHIFY_STAMP" 2>/dev/null)" != "$image_id" || ! -d "$GRAPHIFY_PI/graphify" ]]; then
    graphify_tmp="$(mktemp -d)"
    if podman run --rm --network none --userns="$USERNS" -e HOME=/out \
         -v "$graphify_tmp:/out:z" --entrypoint sh "$IMAGE" -c \
         'cd / && graphify install --platform claude && graphify install --platform pi' >/dev/null 2>&1 \
       && [[ -f "$graphify_tmp/.claude/skills/graphify/SKILL.md" \
             && -f "$graphify_tmp/.pi/agent/skills/graphify/SKILL.md" ]]; then
      mkdir -p "$SKILLS_DIR" "$GRAPHIFY_PI"
      rm -rf -- "$SKILLS_DIR/graphify" "$GRAPHIFY_PI/graphify"
      cp -R -- "$graphify_tmp/.claude/skills/graphify" "$SKILLS_DIR/graphify"
      cp -R -- "$graphify_tmp/.pi/agent/skills/graphify" "$GRAPHIFY_PI/graphify"
      echo "$image_id" > "$GRAPHIFY_STAMP"
      echo "agentbox: installed the graphify skill $(cat "$SKILLS_DIR/graphify/.graphify_version" 2>/dev/null) from the image" >&2
    else
      ab_warn "could not extract the graphify skill from the image"
    fi
    rm -rf -- "$graphify_tmp"
  fi

  SKILLS_SRC=""
  if [[ -d "$SKILLS_DIR" ]]; then
    SKILLS_SRC="$(realpath -e -- "$SKILLS_DIR")"
  fi
}
