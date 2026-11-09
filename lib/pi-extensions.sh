# pi extensions from git repositories: pi-extensions.d/<name>.toml (shared,
# in git) or <AB_HOME>/pi-extensions.local.d/<name>.toml (yours; wins over
# pi-extensions.d/). AB_PI_EXTENSIONS in config.env lists the enabled ones.
# sync-pi-extension.sh installs a source into <AB_HOME>/pi-extensions/<name>,
# which sessions of pi mount read-only as ~/.pi/agent/extensions. Its file
# is TOML data, never run, read by toml_load (lib/toml.sh, kind
# pi-extension-source):
#   url           git URL of the repository (required)
#   ref           branch, tag or commit to pin to (default: the default
#                 branch, with updates offered by check-updates.sh)
#   needs_skills  the skill sources that the extension uses, a list
#
# pi_extensions_sources installs an enabled source that is missing, installs
# again one whose url or ref changed, and removes one that was disabled. It
# compares with the record in <AB_HOME>/pi-extensions.sources/<name>
# (KEY=VALUE, written by sync-pi-extension.sh). It removes only extensions
# that it installed itself (SOURCE=1 in the record). An extension that you
# copied into pi-extensions/ or installed with sync-pi-extension.sh
# yourself stays.
#
# Sourced by run.sh and agentbox setup. Needs lib/paths.sh, lib/config.sh
# (ab_warn), lib/toml.sh, lib/convert.sh and lib/skills.sh (source_load,
# source_value, skill_source_slug).

PI_EXTENSION_SOURCE_DIRS=("$USER_PI_EXTENSIONS_CONF_DIR" "$SCRIPT_DIR/pi-extensions.d")

# 0 if a skill source that has the URL of skill source <name> is in
# AB_SKILLS: under that name, or a source of yours with another name for the
# same repository.
pi_extension_skills_enabled() {  # <skill source name>
  local want n list="${AB_SKILLS:-}"
  want="$(skill_source_slug "$1")"
  for n in ${list//,/ }; do
    [[ "$n" == "$1" ]] && return 0
    [[ -n "$want" && "$(skill_source_slug "$n")" == "$want" ]] && return 0
  done
  return 1
}

# 0 if the start installed pi extension <name>: its record says so, or,
# without a record (an install that stopped before it), its marker.
pi_extension_by_start() {  # <name>
  local rec="$USER_PI_EXTENSIONS_RECORDS/$1" mark="$USER_PI_EXTENSIONS/$1/.agentbox-source"
  if [[ -f "$rec" ]]; then
    [[ "$(source_value "$rec" SOURCE)" == 1 ]]
  else
    [[ "$(head -n1 -- "$mark" 2>/dev/null)" == "$1" ]] && grep -qx 'SOURCE=1' "$mark" 2>/dev/null
  fi
}

pi_extensions_sources() {
  local list="${AB_PI_EXTENSIONS:-}" name url ref rec want have f need needs=()
  local -A enabled=() seen=() desc=() desc_lines=()
  for name in ${list//,/ }; do
    source_load AB_PI_EXTENSIONS "pi extension source" pi-extension-source "$name" desc desc_lines "${PI_EXTENSION_SOURCE_DIRS[@]}" || exit 2
    url="${desc[url]}"
    ref="${desc[ref]:-}"
    enabled[$name]=1
    # An extension that needs the skills of a skill source (needs_skills):
    # its commands fail without them, the rest works. A plain message, not
    # a warning that asks before each session.
    read -ra needs <<<"${desc[needs_skills]:-}"
    for need in ${needs[@]+"${needs[@]}"}; do
      pi_extension_skills_enabled "$need" \
        || echo "agentbox: pi extension '$name' uses the skill source '$need'; without it in AB_SKILLS, its skill commands fail" >&2
    done
    rec="$USER_PI_EXTENSIONS_RECORDS/$name"
    want="$url|$ref|1"
    have=""
    [[ -f "$rec" ]] && have="$(source_value "$rec" URL)|$(source_value "$rec" REF)|$(source_value "$rec" SOURCE)"
    # Also when its directory is gone (removed by hand, a failed install).
    [[ "$want" == "$have" && -d "$USER_PI_EXTENSIONS/$name" ]] && continue
    echo "agentbox: installing pi extension '$name' ($url${ref:+ at $ref})" >&2
    if ! AB_PI_EXTENSIONS_PIN="$ref" AB_PI_EXTENSIONS_SOURCE=1 "$SCRIPT_DIR/sync-pi-extension.sh" "$name" "$url" ${ref:+"$ref"} >&2; then
      ab_warn "could not install pi extension '$name'; continuing with what is installed"
    fi
  done

  # Installed by the start, disabled now: by its record, or by its marker
  # when the install stopped before the record.
  for f in "$USER_PI_EXTENSIONS_RECORDS"/* "$USER_PI_EXTENSIONS"/*/; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    [[ "$name" =~ $AB_NAME_RE && -z "${enabled[$name]:-}" && -z "${seen[$name]:-}" ]] || continue
    seen[$name]=1
    pi_extension_by_start "$name" || continue
    echo "agentbox: removing pi extension '$name', no longer in AB_PI_EXTENSIONS" >&2
    "$SCRIPT_DIR/sync-pi-extension.sh" --remove "$name" >&2 \
      || ab_warn "could not remove pi extension '$name'"
  done
}
