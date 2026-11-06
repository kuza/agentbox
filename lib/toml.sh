# The TOML reader: one unit reads the TOML files that you write.
#
#   toml_load <kind> <file> <values> [<lines>]
#
# Reads <file> of <kind> into the associative array named <values> (key ->
# value for bash) and, when given, into the one named <lines> (key ->
# "<line> <end line>"). Values for bash: an integer as its digits, true as
# 1, false as 0, a list as its items joined with a space. Returns 0; 2 for a
# bad file, with "file:line: reason (code)" on stderr; 3 when there is no
# Python 3.11 or newer. It never exits and never reads the settings from
# the environment: each caller decides what to do.
#
#   lib/toml-schema/<kind>.toml   the keys of a kind: type and required
#   lib/toml-reader.py            the parser (Python, tomllib)
#
# Good results go into a cache in <cache>/agentbox/toml/, keyed by the
# reader version (sha256sum of the reader code and the schemas), the kind
# and the hash of the file. Thus a start with no changed file runs no
# Python, and a changed reader or schema takes effect at the next start.
# The tests in tests/toml/<kind>/ give the expected result of each case.
#
# Needs SCRIPT_DIR and lib/config.sh (ab_warn).

TOML_PYTHON=""   # the interpreter, found at the first need; "-" for none
TOML_VERSION=""  # the reader version

# The first of python3, python3.13, python3.12, python3.11 that is 3.11 or
# newer, into TOML_PYTHON. 1 if there is none.
toml_python() {
  local p
  if [[ -z "$TOML_PYTHON" ]]; then
    TOML_PYTHON=-
    for p in python3 python3.13 python3.12 python3.11; do
      if command -v "$p" >/dev/null && "$p" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
        TOML_PYTHON="$p"
        break
      fi
    done
  fi
  [[ "$TOML_PYTHON" != - ]]
}

# The reader version into TOML_VERSION: sha256sum of the reader code and
# the schemas, once for each process.
toml_version() {
  local lib="$SCRIPT_DIR/lib"
  if [[ -z "$TOML_VERSION" ]]; then
    TOML_VERSION="$(cat -- "$lib/toml.sh" "$lib/toml-reader.py" "$lib"/toml-schema/*.toml | sha256sum)"
    TOML_VERSION="${TOML_VERSION%% *}"
  fi
}

toml_load() {  # <kind> <file> <values> [<lines>]
  local _tl_kind="$1" _tl_file="$2" _tl_lib="$SCRIPT_DIR/lib" _tl_hash _tl_cache _tl_out _tl_rc=0 _tl_f _tl_rec=()
  local -n _tl_values="$3"
  local -A _tl_none=()
  if [[ -n "${4:-}" ]]; then local -n _tl_lines="$4"; else local -n _tl_lines=_tl_none; fi
  if [[ ! -f "$_tl_lib/toml-schema/$_tl_kind.toml" ]]; then
    echo "error: toml_load: no kind '$_tl_kind'" >&2
    return 2
  fi
  toml_version
  if ! _tl_hash="$(sha256sum < "$_tl_file")"; then
    echo "error: cannot read $_tl_file" >&2
    return 2
  fi
  _tl_cache="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/toml/$TOML_VERSION/$_tl_kind-${_tl_hash%% *}"
  _tl_out="$_tl_cache"
  if [[ ! -f "$_tl_cache" ]]; then
    if ! toml_python; then
      echo "error: agentbox needs Python 3.11 or newer (python3, python3.13, python3.12 or python3.11) to read $_tl_file." >&2
      echo "  Fedora: dnf install python3. RHEL 9: dnf install python3.11. Ubuntu 22.04: apt install python3.11." >&2
      return 3
    fi
    # shortcut: the directories of old reader versions stay; remove them if the cache grows.
    if ! mkdir -p "${_tl_cache%/*}" || ! _tl_out="$(mktemp "$_tl_cache.XXXXXX")"; then
      echo "error: cannot write the cache ${_tl_cache%/*}" >&2
      return 2
    fi
    "$TOML_PYTHON" -I "$_tl_lib/toml-reader.py" "$_tl_lib/toml-schema/$_tl_kind.toml" "$_tl_kind" "$_tl_file" > "$_tl_out" || _tl_rc=$?
    if (( _tl_rc != 0 && _tl_rc != 4 )); then
      rm -f -- "$_tl_out"
      echo "error: $_tl_file: the TOML reader failed" >&2
      return 2
    fi
    if (( _tl_rc == 0 )); then
      mv -f -- "$_tl_out" "$_tl_cache" || { rm -f -- "$_tl_out"; return 2; }
      _tl_out="$_tl_cache"
    fi
  fi
  # Records of five fields, each field ends with a NUL (lib/toml-reader.py).
  _tl_values=()
  _tl_lines=()
  while IFS= read -r -d '' _tl_f; do
    _tl_rec+=("$_tl_f")
    (( ${#_tl_rec[@]} == 5 )) || continue
    case "${_tl_rec[0]}" in
      value) _tl_values[${_tl_rec[1]}]="${_tl_rec[4]}"; _tl_lines[${_tl_rec[1]}]="${_tl_rec[2]} ${_tl_rec[3]}" ;;
      warning) ab_warn "$_tl_file:${_tl_rec[2]}: ${_tl_rec[4]} (${_tl_rec[1]})" ;;
      error) echo "$_tl_file:${_tl_rec[2]}: ${_tl_rec[4]} (${_tl_rec[1]})" >&2 ;;
    esac
    _tl_rec=()
  done < "$_tl_out"
  if (( _tl_rc )); then
    rm -f -- "$_tl_out"
    return 2
  fi
}
