# Personal skills: one subdirectory per skill, each with a SKILL.md.
# Mounted read-only over the agent's skills directory so the agent cannot
# rewrite its own skills (they would otherwise persist in its home volume
# across sessions and repos). Project skills in <repo>/.claude/skills need
# nothing: the repo is mounted.
#
# Skill sources: skills.d/<name>.conf (shared, in git) or
# skills.local.d/<name>.conf (yours, ignored by git; wins over skills.d/).
# AB_SKILLS in config.env lists the enabled ones. A source is a git
# repository of skills, installed into the skills directory by
# sync-skills.sh. Its .conf is KEY=VALUE data, never run:
#   URL      git URL of the repository (required)
#   ONLY     comma-separated skills to install, as named there (default: all)
#   PREFIX   prefix for the installed names (default: the repository owner;
#            empty: none)
#   REF      branch, tag or commit to pin to (default: the default branch,
#            with updates offered by check-updates.sh)
#
# skills_sources installs an enabled source that is missing, re-syncs one
# whose .conf changed (at the installed commit, so a changed ONLY does not
# also upgrade it), and removes the skills of a source that was disabled.
# It compares with <skills>/.sources/<owner>__<repo>, the record
# sync-skills.sh keeps; skills synced by hand, without a source, are left
# alone.

SKILLS_SOURCE_DIRS=("$SCRIPT_DIR/skills.local.d" "$SCRIPT_DIR/skills.d")

# Sets SKILLS_DIR and GRAPHIFY_PI, and moves state from where older versions
# kept it. Runs before check-updates.sh, which reads the records.
skills_init() {
  SKILLS_DIR="${AB_SKILLS_DIR:-$SCRIPT_DIR/skills}"
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

source_has() {  # <file> <key>: whether KEY= is present
  grep -q "^$2=" "$1"
}

repo_slug() {  # <url>: owner__repo, as sync-skills.sh computes it
  printf '%s' "$1" | sed -E 's#(\.git)?/*$##; s#^.*[:/]([^/:]+)/([^/]+)$#\1__\2#'
}

sorted_list() {  # <comma-separated list>: sorted, no spaces
  printf '%s' "${1// /}" | tr ',' '\n' | sed '/^$/d' | sort | paste -sd, -
}

skills_sources() {
  local list="${AB_SKILLS:-}" name d conf url only prefix ref slug sync want have at f src
  local -A enabled_url=()
  for name in ${list//,/ }; do
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "error: AB_SKILLS: invalid source name '$name'" >&2
      exit 2
    fi
    conf=""
    for d in "${SKILLS_SOURCE_DIRS[@]}"; do
      if [[ -f "$d/$name.conf" ]]; then conf="$d/$name.conf"; break; fi
    done
    if [[ -z "$conf" ]]; then
      echo "error: AB_SKILLS: no skill source '$name' (looked for skills.local.d/$name.conf and skills.d/$name.conf)" >&2
      exit 2
    fi
    url="$(source_value "$conf" URL)"
    if [[ -z "$url" ]]; then
      echo "error: $conf does not set URL" >&2
      exit 2
    fi
    only="$(sorted_list "$(source_value "$conf" ONLY)")"
    slug="$(repo_slug "$url")"
    if source_has "$conf" PREFIX; then
      prefix="$(source_value "$conf" PREFIX)"
    else
      prefix="$(printf '%s' "${slug%%__*}" | tr '[:upper:]' '[:lower:]')"
    fi
    ref="$(source_value "$conf" REF)"
    enabled_url[$name]="$url"

    sync="$SKILLS_DIR/.sources/$slug"
    want="$url|$only|$prefix|$name|$ref"
    have=""
    if [[ -f "$sync" ]]; then
      have="$(source_value "$sync" URL)|$(sorted_list "$(source_value "$sync" SKILLS_ONLY)")|$(source_value "$sync" SKILLS_PREFIX)|$(source_value "$sync" SOURCE)|$(source_value "$sync" REF)"
    fi
    [[ "$want" == "$have" ]] && continue

    # Pinned: that ref. Changed settings of an installed source: the installed
    # commit, so only the selection changes. New: the default branch.
    at="$ref"
    if [[ -z "$at" && -f "$sync" && "$(source_value "$sync" URL)" == "$url" ]]; then
      at="$(source_value "$sync" COMMIT)"
    fi
    echo "agentbox: syncing skills from '$name' ($url)" >&2
    if ! SKILLS_ONLY="$only" SKILLS_PREFIX="$prefix" AB_SKILLS_DIR="$SKILLS_DIR" \
         SKILLS_SOURCE="$name" SKILLS_PIN="$ref" \
         "$SCRIPT_DIR/sync-skills.sh" "$url" ${at:+"$at"} >&2; then
      echo "agentbox: warning: could not sync skills from '$name'; continuing with what is installed" >&2
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
      || echo "agentbox: warning: could not remove skills from '$src'" >&2
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
  image_id="$(podman image inspect -f '{{.Id}}' "$IMAGE")"
  if [[ -e "$SKILLS_DIR/graphify" && ! -f "$GRAPHIFY_STAMP" ]]; then
    echo "agentbox: warning: $SKILLS_DIR/graphify was not installed by agentbox; not updating it" >&2
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
      echo "agentbox: warning: could not extract the graphify skill from the image" >&2
    fi
    rm -rf -- "$graphify_tmp"
  fi

  SKILLS_SRC=""
  if [[ -d "$SKILLS_DIR" ]]; then
    SKILLS_SRC="$(realpath -e -- "$SKILLS_DIR")"
  fi
}
