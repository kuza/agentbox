# The conversion of your files from agentbox v0.1.x to TOML, one time, and
# the removal of the old files after the conversion.
#
#   convert_old_files   the entry point: run.sh and agentbox setup call it
#                       before they read the settings
#   old_files_list      the old files, and which of them can go (the item
#                       o of agentbox setup)
#   old_files_remove    removes old files that can go, under the lock
#   old_files_remind    the reminder of the start, at most one time a day
#
# Each old file <name>.conf or <name>.env becomes <name>.toml next to it
# (lib/toml-writer.py), and toml_load reads it back before it is used.
# CONVERT_LIST has the path of each converted old file, one on each line,
# or "kept <path>" when a TOML file of yours was there first. A file in the list is not
# converted again, even when you remove its TOML file. To convert a file
# again, remove its line from the list. A file that cannot be converted
# gets a warning and stays out of the list: the start goes on, and the
# next start tries again. A start with nothing to
# convert runs no Python. A flock on CONVERT_LOCK lets one process convert
# or remove at a time; the kernel releases it when the process stops.
#
# An old file can go only when all of these are true:
#   - the list marks it as converted (not kept);
#   - its TOML file is there;
#   - the old file is not newer than its TOML file;
#   - AB_CONFIG does not name it;
#   - its path is absolute;
#   - this process found it in a place of old files (old_files_place).
# Thus a path that you add to the list by hand stays. A .env file in the
# environment directory is never a place of old files: <repo>.env has the
# passwords of a repo.
#
# To add a kind of file, add a convert_find call to convert_old_files. Give
# it the kind of the schema (lib/toml-schema/), the form of the old file
# (lib/toml-writer.py) and the old files. If a step must read a converted
# file, call convert_run first, then convert_find again.
#
# Needs SCRIPT_DIR, lib/paths.sh, lib/config.sh (ab_warn, CONFIG_FILE,
# CONFIG_OLD_FILE) and lib/toml.sh.

CONVERT_LIST="$AB_HOME_DIR/converted.list"
CONVERT_LOCK="$AB_HOME_DIR/convert.lock"
CONVERT_TODO=()  # "<kind> <form> <old file>"
declare -A CONVERT_LISTED=()  # <old file> -> converted or kept
# Each old file that this process found on disk, in a place of old files.
# CONVERT_FOUND_PARTIAL is 1 when the environment directory was not read:
# then CONVERT_FOUND can lack some old files.
declare -A CONVERT_FOUND=()
CONVERT_FOUND_PARTIAL=""
# The environment directory that convert_old_files read, as a full path.
# Empty when it did not read it.
CONVERT_ENV_DIR=""
# From old_files_list.
OLD_FILES_PATH=() OLD_FILES_CAN=() OLD_FILES_REASON=()
# The time of the last reminder (old_files_remind) is the mtime of this
# file. Each settings directory has its own stamp.
OLD_FILES_STAMP="$AB_HOME_DIR/.old-files-reminded"

# CONVERT_LIST into CONVERT_LISTED, one read for each process.
convert_read_list() {
  local line
  CONVERT_LISTED=()
  [[ -f "$CONVERT_LIST" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" == "kept "* ]]; then CONVERT_LISTED[${line#kept }]=kept; elif [[ -n "$line" ]]; then CONVERT_LISTED[$line]=converted; fi
  done < "$CONVERT_LIST"
}

convert_old_files() {
  local env_dir="${AB_ENV_DIR:-}"
  local -A settings=()
  CONVERT_FOUND=(); CONVERT_FOUND_PARTIAL=""; CONVERT_ENV_DIR=""
  convert_read_list
  # Step 1: the settings file. Step 2 reads AB_ENV_DIR in it.
  convert_find config keys "$CONFIG_OLD_FILE"
  convert_run
  if [[ -z "${AB_ENV_DIR+x}" ]] && convert_pending "$CONFIG_OLD_FILE"; then
    # Step 1 failed: the AB_ENV_DIR of the old file is not known.
    env_dir=-
  elif [[ -z "${AB_ENV_DIR+x}" && -f "$CONFIG_FILE" ]]; then
    # A file that cannot be read stops the start later, with its error. Its
    # AB_ENV_DIR is not known, so no directory is converted now.
    if toml_load config "$CONFIG_FILE" settings 2>/dev/null; then env_dir="${settings[AB_ENV_DIR]:-}"; else env_dir=-; fi
  fi
  if [[ "$env_dir" == - ]]; then
    CONVERT_FOUND_PARTIAL=1
  else
    CONVERT_ENV_DIR="$(realpath -m -- "${env_dir:-$USER_ENV_DIR}")"
    convert_find config keys "${env_dir:-$USER_ENV_DIR}"/*.conf
  fi
  convert_find egress-group hosts "$USER_EGRESS_DIR"/*.conf
  convert_find skill-source source "$USER_SKILLS_SOURCES_DIR"/*.conf
  convert_find pi-extension-source source "$USER_PI_EXTENSIONS_CONF_DIR"/*.conf
  convert_run
}

convert_listed() { [[ -n "${CONVERT_LISTED[$1]+x}" ]]; }  # <old file>

# 0 when <old file> of yours is there and is not converted (the conversion
# warned). Then a start must not use the shared file of the same name in
# its place.
convert_pending() { [[ -f "$1" ]] && ! convert_listed "$1"; }  # <old file>

# The TOML file of <name>: the first <dir>/<name>.toml. Each caller looks it
# up here, so that the rule of convert_pending is in one place. Returns 3
# and prints your old file when it is not converted: then the shared file
# of that name does not count. Returns 1 when there is no file.
convert_toml_find() {  # <name> <dirs: yours, then shared>
  if convert_pending "$2/$1.conf"; then
    printf '%s\n' "$2/$1.conf"
    return 3
  fi
  conf_find "$1" toml "${@:2}"
}

# Says why a TOML file is not there when its old file was converted (you
# removed the TOML file). A start calls it before it stops on the missing
# TOML file. An old file that is not converted stops the start earlier
# (convert_pending).
convert_why_missing() {  # <old file>
  if [[ -f "$1" ]] && convert_listed "$1"; then
    echo "  $1 was converted before. To convert it again, remove its line from $CONVERT_LIST." >&2
  fi
}

convert_add() {  # <old file> <converted|kept>
  if [[ "$2" == kept ]]; then printf 'kept %s\n' "$1"; else printf '%s\n' "$1"; fi >> "$CONVERT_LIST"
  CONVERT_LISTED[$1]="$2"
}

# Each old file that is not in the list goes into CONVERT_TODO. An old file
# that agentbox converted and that is newer than its TOML file gets a
# warning. That is a change after a rollback, and this version does not
# read it.
convert_find() {  # <kind> <form> <old files...>
  local kind="$1" form="$2" old new
  shift 2
  for old in "$@"; do
    [[ -f "$old" ]] || continue
    CONVERT_FOUND[$old]=1
    new="${old%.*}.toml"
    if ! convert_listed "$old"; then
      CONVERT_TODO+=("$kind $form $old")
    elif [[ "${CONVERT_LISTED[$old]}" == converted && -f "$new" && "$old" -nt "$new" ]]; then
      ab_warn "$old is newer than $new. agentbox reads only the TOML file: put your change there."
    fi
  done
}

# Converts the files in CONVERT_TODO under the lock. Names each file on
# stderr.
convert_run() {
  local entry kind form old new lock converted=()
  (( ${#CONVERT_TODO[@]} )) || return 0
  if ! toml_python; then
    toml_no_python "convert your files to TOML"
    exit 2
  fi
  mkdir -p "$AB_HOME_DIR"
  exec {lock}>> "$CONVERT_LOCK"
  flock "$lock"
  # Another process may have converted files while this one waited.
  convert_read_list
  for entry in "${CONVERT_TODO[@]}"; do
    read -r kind form old <<< "$entry"
    convert_listed "$old" && continue
    new="${old%.*}.toml"
    # A TOML file that you wrote yourself stays as it is.
    if [[ -e "$new" ]]; then
      converted+=("$old: not converted, $new is there")
      convert_add "$old" kept
    elif convert_file "$kind" "$form" "$old" "$new"; then
      converted+=("$old -> $(basename -- "$new")")
      convert_add "$old" converted
    fi
    if [[ "$old" == "${AB_CONFIG:-}" ]] && convert_listed "$old"; then
      converted+=("AB_CONFIG names $old: change it to $new.")
    fi
  done
  exec {lock}>&-
  CONVERT_TODO=()
  if (( ${#converted[@]} )); then
    echo "agentbox: the conversion of your files to TOML. The old files stay. To remove them, use agentbox setup, item o." >&2
    echo "Converted files:" >&2
    printf '  %s\n' "${converted[@]}" >&2
    echo "agentbox: $CONVERT_LIST lists the converted files. To convert a file again, remove its line from the list." >&2
  fi
}

# Writes <new> from <old> and reads it back with toml_load. Returns 2, with
# a warning that names the line, when <old> cannot be converted.
convert_file() {  # <kind> <form> <old> <new>
  local kind="$1" form="$2" old="$3" new="$4" tmp="$4.new" msgs line rc=0
  local -A values=()
  # A fixed name is safe under the lock.
  msgs="$("$TOML_PYTHON" -I "$SCRIPT_DIR/lib/toml-writer.py" "$SCRIPT_DIR/lib/toml-schema/$kind.toml" "$form" "$old" 2>&1 > "$tmp")" || rc=$?
  if (( rc == 0 )); then
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then ab_warn "$line"; fi
    done <<< "$msgs"
    if ! toml_load "$kind" "$tmp" values; then
      mv -f -- "$tmp" "$new.rejected"
      ab_warn "agentbox wrote $new.rejected from $old (the errors above name it $tmp), and cannot read it. This is a fault of agentbox: report it with both files."
      return 2
    fi
  elif (( rc == 4 )); then
    while IFS= read -r line; do ab_warn "$line"; done <<< "$msgs"
  else
    ab_warn "$old: the conversion to TOML failed: $msgs"
  fi
  if (( rc )); then
    rm -f -- "$tmp"
    ab_warn "agentbox did not convert $old to TOML, and does not read it. Correct it, and start again."
    return 2
  fi
  chmod --reference="$old" -- "$tmp"
  mv -f -- "$tmp" "$new"
}

# 0 when this process found <old file> in a place of old files. A .env file
# in the environment directory is not one: <repo>.env has the passwords of
# a repo. This rule applies also to the settings file of v0.1.x. When the
# environment directory is not known, no .env file is one.
old_files_place() {  # <old file>
  [[ -n "${CONVERT_FOUND[$1]+x}" ]] || return 1
  [[ "$1" == *.env ]] || return 0
  [[ -n "$CONVERT_ENV_DIR" && "$(realpath -m -- "$(dirname -- "$1")")" != "$CONVERT_ENV_DIR" ]]
}

# Why <old file> cannot go: the first reason that applies, or nothing when
# it can go. Uses CONVERT_LISTED and old_files_place.
old_files_why() {  # <old file>
  local old="$1" new="${1%.*}.toml"
  if [[ "${CONVERT_LISTED[$old]-}" == kept ]]; then echo "kept: your TOML file was there before the conversion"
  elif ! convert_listed "$old"; then echo "did not convert: read the warning of the start"
  elif [[ ! -f "$new" ]]; then echo "no TOML file: $new is missing"
  elif [[ "$old" -nt "$new" ]]; then echo "changed after the conversion: move the change to $new"
  elif [[ "$old" == "${AB_CONFIG:-}" ]]; then echo "AB_CONFIG names it: change AB_CONFIG to the .toml file first"
  elif [[ "$old" != /* ]]; then echo "relative path: remove it yourself"
  elif ! old_files_place "$old" && [[ -n "$CONVERT_FOUND_PARTIAL" ]]; then echo "the settings file cannot be read"
  elif ! old_files_place "$old"; then echo "not a place of old files: remove it yourself"
  fi
}

# The old files on disk: the paths of CONVERT_LIST in their order, then the
# old files that did not convert. Fills OLD_FILES_PATH, OLD_FILES_CAN (1:
# it can go, 0: it stays) and OLD_FILES_REASON (old_files_why). Returns 0
# when at least one file can go. Call convert_old_files first.
old_files_list() {
  local old why can=1
  local -A seen=()
  OLD_FILES_PATH=(); OLD_FILES_CAN=(); OLD_FILES_REASON=()
  convert_read_list
  while IFS= read -r old; do
    [[ -n "$old" && -z "${seen[$old]+x}" && -f "$old" ]] || continue
    seen[$old]=1
    why="$(old_files_why "$old")"
    OLD_FILES_PATH+=("$old"); OLD_FILES_REASON+=("$why")
    if [[ -z "$why" ]]; then OLD_FILES_CAN+=(1); can=0; else OLD_FILES_CAN+=(0); fi
  done < <(
    if [[ -f "$CONVERT_LIST" ]]; then
      while IFS= read -r old; do printf '%s\n' "${old#kept }"; done < "$CONVERT_LIST"
    fi
    for old in "${!CONVERT_FOUND[@]}"; do convert_listed "$old" || printf '%s\n' "$old"; done | sort
  )
  return "$can"
}

# Removes each <old file> that can go now, and its line in CONVERT_LIST.
# Under the lock, it reads the list and the files again: a start at the
# same time can change them. It also removes the line of each file that is
# not on disk. It keeps a relative line, and the line of a file that rm
# cannot remove. Prints "removed <path>" or "kept <path>: <reason>" for
# each <old file> on disk. Returns 0 when it removed each of them, 1 when
# one stays, and 2 when it cannot take the lock or write the list.
old_files_remove() {  # <old files...>
  local lock old why line rc=0 removed="" total=0 lines=()
  if ! { mkdir -p -- "$AB_HOME_DIR" && exec {lock}>> "$CONVERT_LOCK"; } 2>/dev/null; then
    echo "error: cannot change $CONVERT_LIST: nothing removed" >&2
    return 2
  fi
  if ! flock "$lock"; then
    exec {lock}>&-
    echo "error: cannot change $CONVERT_LIST: nothing removed" >&2
    return 2
  fi
  convert_read_list
  for old in "$@"; do
    [[ -f "$old" ]] || continue
    why="$(old_files_why "$old")"
    if [[ -z "$why" ]] && ! rm -f -- "$old" 2>/dev/null; then why="cannot remove it"; fi
    if [[ -z "$why" ]]; then
      echo "removed $old"
      removed=1
    else
      echo "kept $old: $why"
      rc=1
    fi
  done
  if [[ -f "$CONVERT_LIST" ]]; then
    while IFS= read -r line; do
      total=$((total + 1))
      old="${line#kept }"
      if [[ -n "$line" ]] && [[ "$old" != /* || -f "$old" ]]; then lines+=("$line"); fi
    done < "$CONVERT_LIST"
    # A fixed name is safe under the lock.
    if (( ${#lines[@]} != total )) && ! { { if (( ${#lines[@]} )); then printf '%s\n' "${lines[@]}"; fi; } > "$CONVERT_LIST.new" &&
        mv -f -- "$CONVERT_LIST.new" "$CONVERT_LIST"; } 2>/dev/null; then
      rm -f -- "$CONVERT_LIST.new" 2>/dev/null
      if [[ -n "$removed" ]]; then
        echo "error: removed the files, but cannot write $CONVERT_LIST; the next removal cleans it" >&2
      else
        echo "error: cannot change $CONVERT_LIST: nothing removed" >&2
      fi
      rc=2
    fi
  fi
  convert_read_list
  exec {lock}>&-
  return "$rc"
}

# The reminder of the start: one line on stderr when at least one old file
# can go, at most one time a day. A missing stamp is older than one day. A
# stamp time in the future (a clock that was wrong) is also old. The stamp
# changes only after the line. Always returns 0: a failed touch does not
# stop the start. Call convert_old_files first.
old_files_remind() {
  local mark age count=0 text=files
  if [[ -f "$OLD_FILES_STAMP" ]]; then
    age=$(( $(date +%s) - $(stat -L -c %Y -- "$OLD_FILES_STAMP" 2>/dev/null || echo 0) ))
    (( age >= 0 && age < 86400 )) && return 0
  fi
  old_files_list || return 0
  for mark in "${OLD_FILES_CAN[@]}"; do count=$((count + mark)); done
  (( count == 1 )) && text="file"
  echo "agentbox: $count old $text of v0.1.x can go: agentbox setup, item o" >&2
  touch -- "$OLD_FILES_STAMP" 2>/dev/null || true
  return 0
}
