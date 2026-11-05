# pi extensions from git repositories: pi-extensions.d/<name>.conf (shared,
# in git) or <AB_HOME>/pi-extensions.local.d/<name>.conf (yours; wins over
# pi-extensions.d/). AB_PI_EXTENSIONS in config.env lists the enabled ones.
# sync-pi-extension.sh installs a source into <AB_HOME>/pi-extensions/<name>,
# which sessions of pi mount read-only as ~/.pi/agent/extensions. Its .conf
# is KEY=VALUE data, never run:
#   URL   git URL of the repository (required)
#   REF   branch, tag or commit to pin to (default: the default branch, with
#         updates offered by check-updates.sh)
#
# pi_extensions_sources installs an enabled source that is missing, installs
# again one whose URL or REF changed, and removes one that was disabled. It
# compares with the record in <AB_HOME>/pi-extensions.sources/<name>. It
# removes only extensions that it installed itself (SOURCE=1 in the record).
# An extension that you copied into pi-extensions/ or installed with
# sync-pi-extension.sh yourself stays.
#
# Sourced by run.sh and agentbox setup. Needs lib/paths.sh, lib/config.sh
# (conf_find, ab_warn) and lib/skills.sh (source_conf, source_value).

PI_EXTENSION_SOURCE_DIRS=("$USER_PI_EXTENSIONS_CONF_DIR" "$SCRIPT_DIR/pi-extensions.d")

pi_extensions_sources() {
  local list="${AB_PI_EXTENSIONS:-}" name conf url ref rec want have f d need skills
  local -A enabled=()
  for name in ${list//,/ }; do
    conf="$(source_conf AB_PI_EXTENSIONS "pi extension source" "$name" "${PI_EXTENSION_SOURCE_DIRS[@]}")" || exit 2
    url="$(source_value "$conf" URL)"
    ref="$(source_value "$conf" REF)"
    enabled[$name]=1
    # An extension that needs the skills of a skill source (NEEDS_SKILLS):
    # its commands fail without them, the rest works. A plain message, not
    # a warning that asks before each session.
    for need in $(source_value "$conf" NEEDS_SKILLS | tr ',' ' '); do
      skills="${AB_SKILLS:-}"
      [[ " ${skills//,/ } " == *" $need "* ]] \
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

  # Installed by agentbox, disabled now.
  for f in "$USER_PI_EXTENSIONS_RECORDS"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    [[ "$name" =~ $AB_NAME_RE ]] || continue
    [[ -n "${enabled[$name]:-}" ]] && continue
    [[ "$(source_value "$f" SOURCE)" == 1 ]] || continue
    echo "agentbox: removing pi extension '$name', no longer in AB_PI_EXTENSIONS" >&2
    "$SCRIPT_DIR/sync-pi-extension.sh" --remove "$name" >&2 \
      || ab_warn "could not remove pi extension '$name'"
  done
  # The same for one whose install stopped before its record: its mark says
  # that the start installed it.
  for d in "$USER_PI_EXTENSIONS"/*/; do
    name="$(basename "$d")"
    [[ "$name" =~ $AB_NAME_RE && -z "${enabled[$name]:-}" && ! -f "$USER_PI_EXTENSIONS_RECORDS/$name" ]] || continue
    [[ "$(head -n1 -- "$d.agentbox-source" 2>/dev/null)" == "$name" ]] || continue
    grep -qx 'SOURCE=1' "$d.agentbox-source" 2>/dev/null || continue
    echo "agentbox: removing pi extension '$name', no longer in AB_PI_EXTENSIONS" >&2
    "$SCRIPT_DIR/sync-pi-extension.sh" --remove "$name" >&2 \
      || ab_warn "could not remove pi extension '$name'"
  done
}
