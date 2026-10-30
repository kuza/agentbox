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
# does not see them. Older versions kept them next to the code; run.sh stops
# while any is still there (user_paths_check_old).
#
# Sourced by run.sh, check-updates.sh and sync-skills.sh; needs SCRIPT_DIR.
# Sets AB_HOME_DIR and the USER_* paths below.

AB_HOME_DIR="${AB_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/agentbox}"

USER_CONFIG="$AB_HOME_DIR/config.env"
USER_ENV_DIR="$AB_HOME_DIR/env"
USER_SKILLS_DIR="$AB_HOME_DIR/skills"
USER_AGENTS_MD="$AB_HOME_DIR/AGENTS.md"
USER_MCP_DIR="$AB_HOME_DIR/mcp.local"
USER_SKILLS_SOURCES_DIR="$AB_HOME_DIR/skills.local.d"
USER_EGRESS_DIR="$AB_HOME_DIR/egress.local.d"
USER_PI_EXTENSIONS="$AB_HOME_DIR/pi-extensions"

# Old place next to the code -> name in AB_HOME.
OLD_PLACES=(
  "config.env config.env" "env env" "skills skills" "agents/AGENTS.md AGENTS.md"
  "mcp.local mcp.local" "skills.local.d skills.local.d" "egress.local.d egress.local.d"
  "pi/extensions pi-extensions"
)

# Refuses a repo that is, contains or lies inside agentbox's code, the other
# installed versions, git-guard or your files: a session could change code
# that runs on the host (rollback switches to another version; git-guard
# runs on every git call), or read the passwords in env/ or in the
# sidecars' copies in the cache (mcp/dbhub). Run once the
# settings are read (AB_ENV_DIR, AB_SKILLS_DIR, AB_CONFIG may move them).
# Needs INSTALL_DIR (lib/release.sh).
user_paths_check_repo() {  # <repo> <env dir> <skills dir> <config file>
  local repo="$1" p what
  for p in "code:$SCRIPT_DIR" "installed versions:$INSTALL_DIR" "git-guard:$HOME/.local/bin/git" "your files:$AB_HOME_DIR" "sidecars' copies:${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/sidecars" "env dir:$2" "skills dir:$3" "config file:$4"; do
    what="${p%%:*}"; p="$(realpath -m -- "${p#*:}")"
    if [[ "$repo" == "$p" || "$p" == "$repo"/* || "$repo" == "$p"/* || "$repo" == / ]]; then
      echo "error: refusing to mount $repo: it overlaps agentbox's $what ($p)." >&2
      echo "  A session could change code that runs on your host, or read your settings and passwords." >&2
      echo "  To work on agentbox, open a separate clone of it, not the copy you run (README, Your files)." >&2
      exit 2
    fi
  done
}

# Stops if any of your files is still next to the code, where older versions
# kept it: it would be silently ignored (a config.env with settings, env/
# with passwords), and git would show it in agentbox's repository. Prints
# how to move each. Empty directories (pi/extensions created by an older
# run.sh) are just removed.
user_paths_check_old() {
  local entry old new found=()
  for entry in "${OLD_PLACES[@]}"; do
    old="$SCRIPT_DIR/${entry%% *}"; new="$AB_HOME_DIR/${entry#* }"
    [[ -e "$old" ]] || continue
    if [[ -d "$old" ]] && rmdir -- "$old" 2>/dev/null; then continue; fi
    if [[ -e "$new" ]]; then
      found+=("  # both exist: merge $old into $new by hand, then remove $old")
    else
      found+=("  mv '$old' '$new'")
    fi
  done
  (( ${#found[@]} )) || return 0
  echo "error: your files belong in $AB_HOME_DIR, apart from the code (README, Your files)." >&2
  echo "These are still next to the code; move them:" >&2
  echo "  mkdir -p '$AB_HOME_DIR'" >&2
  printf '%s\n' "${found[@]}" >&2
  exit 2
}
