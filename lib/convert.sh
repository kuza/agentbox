# The conversion of your files from agentbox v0.1.x to TOML, one time.
#
#   convert_old_files   the entry point: run.sh and agentbox setup call it
#                       before they read the settings
#
# Each old file <name>.conf or <name>.env becomes <name>.toml next to it
# (lib/toml-writer.py), and toml_load reads it back before it is used. The
# old file stays unchanged, for a rollback to v0.1.x. CONVERT_LIST has the
# path of each converted old file, one on each line, or "kept <path>" when
# a TOML file of yours was there first. A file in the list is not
# converted again, even when you remove its TOML file. To convert a file
# again, remove its line from the list. A file that cannot be converted
# gets a warning and stays out of the list: the start goes on, and the
# next start tries again. A start with nothing to
# convert runs no Python. A flock on CONVERT_LOCK lets one process convert
# at a time; the kernel releases it when the process stops.
#
# To add a kind of file, add a convert_find call to convert_old_files. Give
# it the kind of the schema (lib/toml-schema/), the form of the old file
# (lib/toml-writer.py) and the old files. If a step must read a converted
# file, call convert_run first, then convert_find again.
#
# shortcut: the list only grows; clean it in v0.3.0, which removes the old
# files.
#
# Needs SCRIPT_DIR, lib/paths.sh, lib/config.sh (ab_warn, CONFIG_FILE,
# CONFIG_OLD_FILE) and lib/toml.sh.

CONVERT_LIST="$AB_HOME_DIR/converted.list"
CONVERT_LOCK="$AB_HOME_DIR/convert.lock"
CONVERT_TODO=()  # "<kind> <form> <old file>"
declare -A CONVERT_LISTED=()  # <old file> -> converted or kept

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
  [[ "$env_dir" == - ]] || convert_find config keys "${env_dir:-$USER_ENV_DIR}"/*.conf
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
    echo "agentbox: the conversion of your files to TOML. The old files stay unchanged, for a rollback to v0.1.x:" >&2
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
