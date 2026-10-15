# Your files live apart from agentbox's code, in AB_HOME (default
# ~/.config/agentbox):
#
#   config.env         settings
#   env/               per-project environment and settings, <repo>.env/.conf
#   skills/            personal and vendored skills
#   AGENTS.md          personal instructions for both agents
#   mcp.local/         your MCP modules
#   skills.local.d/    your skill sources
#   egress.local.d/    your egress groups
#   pi-extensions/     pi extensions you allow
#
# The code can then be replaced (a new version, a fresh clone) without
# touching them, and a session that has agentbox's code open as its repo
# does not see them. Older versions kept them next to the code; each one
# found only there is still used, with a warning saying how to move it.
#
# Sourced by run.sh, check-updates.sh and sync-skills.sh; needs SCRIPT_DIR.
# Sets AB_HOME_DIR, the USER_* paths below and OLD_PLACES.

AB_HOME_DIR="${AB_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/agentbox}"
OLD_PLACES=()

user_path() {  # <variable> <name in AB_HOME> <old name next to the code>
  if [[ ! -e "$AB_HOME_DIR/$2" && -e "$SCRIPT_DIR/$3" ]]; then
    OLD_PLACES+=("$3 $2")
    printf -v "$1" '%s' "$SCRIPT_DIR/$3"
  else
    printf -v "$1" '%s' "$AB_HOME_DIR/$2"
  fi
}

user_path USER_CONFIG config.env config.env
user_path USER_ENV_DIR env env
user_path USER_SKILLS_DIR skills skills
user_path USER_AGENTS_MD AGENTS.md agents/AGENTS.md
user_path USER_MCP_DIR mcp.local mcp.local
user_path USER_SKILLS_SOURCES_DIR skills.local.d skills.local.d
user_path USER_EGRESS_DIR egress.local.d egress.local.d
user_path USER_PI_EXTENSIONS pi-extensions pi/extensions

# Refuses a repo that is, contains or lies inside agentbox's code or your
# files: a session could change code that runs on the host, or read the
# passwords in env/. Run once the settings are read (AB_ENV_DIR,
# AB_SKILLS_DIR, AB_CONFIG may move them).
user_paths_check_repo() {  # <repo> <env dir> <skills dir> <config file>
  local repo="$1" p what
  for p in "code:$SCRIPT_DIR" "your files:$AB_HOME_DIR" "env dir:$2" "skills dir:$3" "config file:$4"; do
    what="${p%%:*}"; p="$(realpath -m -- "${p#*:}")"
    if [[ "$repo" == "$p" || "$p" == "$repo"/* || "$repo" == "$p"/* || "$repo" == / ]]; then
      echo "error: refusing to mount $repo: it overlaps agentbox's $what ($p)." >&2
      echo "  A session could change code that runs on your host, or read your settings and passwords." >&2
      echo "  To work on agentbox, open a separate clone of it, not the copy you run (README, Your files)." >&2
      exit 2
    fi
  done
}

# Run once per start (run.sh): how to move what is still in the old place.
user_paths_warn() {
  local entry
  (( ${#OLD_PLACES[@]} )) || return 0
  echo "agentbox: warning: your files belong in $AB_HOME_DIR now, apart from the code (README, Your files)." >&2
  echo "agentbox: these are still next to the code and used from there; to move them:" >&2
  echo "  mkdir -p '$AB_HOME_DIR'" >&2
  for entry in "${OLD_PLACES[@]}"; do
    echo "  mv '$SCRIPT_DIR/${entry%% *}' '$AB_HOME_DIR/${entry#* }'" >&2
  done
}
