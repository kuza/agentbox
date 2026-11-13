# agentbox uninstall: removes what agentbox put on this host.
#
#   agentbox uninstall            shows the list and asks; asks separately
#                                 about Podman secrets and your files
#   agentbox uninstall --yes      without asking; keeps secrets and your files
#   agentbox uninstall --yes --all  everything, secrets and your files too
#
# Removed: containers, volumes and networks named ab-* (open sessions end;
# your own containers attached to ab-services are only disconnected, never
# removed), the host services modules started (agentbox-*), agentbox's
# images, the cache, git-guard (~/.local/bin/git, if it is git-guard),
# ~/.config/environment.d/agentbox.conf, the agentbox command with its bash
# completion, and the installed versions. Secrets: those
# agentbox and its modules use.
# Your files: <AB_HOME> (config.toml, env/ with passwords, skills, ...).
# Needs SCRIPT_DIR, lib/paths.sh, lib/release.sh, IMG_* from lib/config.sh,
# lib/sidecars.sh, lib/egress.sh and lib/mcp.sh (mcp_names,
# mcp_uninstall_names).

# The mcp.sh of each module of the old format in mcp_names: yours and the
# shared one, also when yours replaces it. Images and secrets of both can be
# on the host. A manifest module goes to mcp_uninstall_names.
uninstall_mcp_files() {
  local n d
  while IFS= read -r n; do
    for d in "${MCP_DIRS[@]}"; do
      [[ ! -f "$d/$n/mcp.sh" || -f "$d/$n/module.toml" ]] || printf '%s\n' "$d/$n/mcp.sh"
    done
  done < <(mcp_names)
}

# Values of an MCP_ variable in all modules, read as text, not run: names
# like grafana_sa or images like ghcr.io/x/y:tag, in "", '' or no quotes,
# on one line, indented or not. A "$VAR" or "${VAR}" there is looked up as a
# VAR= line of the same file (MCP_IMAGES=("$SERVER_IMAGE")); one the file
# does not set ("$IMG_NGINX") is left out, agentbox_uninstall removes it
# anyway.
uninstall_names() {  # <MCP_ variable>
  local f v vals
  while IFS= read -r f; do
    # Split, never globbed; a trailing comment is not a name.
    read -ra vals <<<"$(sed -n "s/^[[:space:]]*$1=//p" "$f" | sed 's/[[:space:]]#.*//' | tr -d "()\"'" | tr '\n' ' ')"
    for v in ${vals[@]+"${vals[@]}"}; do
      if [[ "$v" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
        sed -n "s/^[[:space:]]*${BASH_REMATCH[1]}=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$f"
      else
        printf '%s\n' "$v"
      fi
    done
  done < <(uninstall_mcp_files) | grep -E '^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$' | sort -u
}

# The values in config.toml into the array <values>: the file only, not
# the environment. Status 1 when it cannot read the file (no Python 3.11,
# or an error): then it says so on stderr. UNINSTALL_CONFIG is the file.
uninstall_config() {  # <values>
  local -n _uc_values="$1"
  local path tmp="" msgs rc=0
  UNINSTALL_CONFIG="$CONFIG_FILE"
  # Before the first start of v0.2.0, config.env is not converted: read a
  # converted copy of it.
  [[ ! -f "$UNINSTALL_CONFIG" && -f "$CONFIG_OLD_FILE" ]] && UNINSTALL_CONFIG="$CONFIG_OLD_FILE"
  path="$UNINSTALL_CONFIG"
  if [[ ! -f "$path" ]]; then
    return 0
  elif ! toml_python; then
    toml_no_python "read $path" warning
    return 1
  elif [[ "$path" == "$CONFIG_OLD_FILE" ]]; then
    # The messages of the writer name lines of config.env: shown only when
    # it cannot convert the file.
    if tmp="$(mktemp)" && msgs="$("$TOML_PYTHON" -I "$SCRIPT_DIR/lib/toml-writer.py" "$SCRIPT_DIR/lib/toml-schema/config.toml" keys "$path" 2>&1 > "$tmp")"; then
      path="$tmp"
    else
      [[ -n "${msgs:-}" ]] && printf '%s\n' "$msgs" >&2
      rm -f -- "$tmp"
      return 1
    fi
  fi
  # A file that cannot be read gives an error, and its secrets stay.
  toml_load config "$path" _uc_values || rc=1
  rm -f -- "$tmp"
  return "$rc"
}

# The Podman secrets whose names come from a setting of a module of the old
# format: MCP_SECRETS_BY_SETTING=("<KEY> <prefix>"), read as text. For
# ("MY_TEAMS my_team_"): my_team_<team> for each team in <values>
# (uninstall_config), in lowercase. Only those: a secret of the
# same prefix that agentbox does not use stays. Without <values>, it keeps
# those secrets and says so on stderr.
uninstall_secrets_by_setting() {  # [<values>]
  local f key prefix v list
  local -A _usbs_none=()
  local -n _usbs_values="${1:-_usbs_none}"
  while IFS= read -r f; do
    sed -n 's/^[[:space:]]*MCP_SECRETS_BY_SETTING=(\(.*\))[[:space:]]*$/\1/p' "$f" | tr -d "\"'"
  done < <(uninstall_mcp_files) | while read -r key prefix; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$prefix" =~ ^[a-z0-9_]+$ ]] || continue
    if [[ -z "${1:-}" ]]; then
      echo "agentbox: agentbox cannot read $key in $UNINSTALL_CONFIG, so it keeps any secrets $prefix<name>. If you have such secrets, remove them yourself (podman secret ls)." >&2
      continue
    fi
    IFS=', ' read -ra list <<<"${_usbs_values[$key]:-}"
    for v in ${list[@]+"${list[@]}"}; do
      v="${v,,}"
      [[ "$v" =~ ^[a-z0-9][a-z0-9-]*$ ]] && printf '%s%s\n' "$prefix" "$v"
    done
  done | sort -u
}

agentbox_uninstall() {
  local yes="" all="" reply secrets_too="" files_too="" a c v n id config="" cache
  local -A config_values=()
  for a in "$@"; do
    case "$a" in
      --yes) yes=1 ;;
      --all) all=1 ;;
      *) echo "error: unknown option '$a' (agentbox uninstall [--yes] [--all])" >&2; return 2 ;;
    esac
  done
  ask() {  # <question>: yes with --yes, else the answer on a terminal
    [[ -n "$yes" ]] && return 0
    [[ -t 0 ]] || return 1
    read -r -p "agentbox: $1 [y/N] " reply
    [[ "$reply" == [yY]* ]]
  }

  echo "agentbox uninstall removes:"
  echo "  containers, volumes, networks named ab-* (open sessions end; Claude Code and pi"
  echo "    logins, session history and caches go with the volumes)"
  echo "  host services of MCP modules (systemd user services agentbox-*)"
  echo "  images: localhost/agentbox and the sidecar images"
  echo "  ${XDG_CACHE_HOME:-$HOME/.cache}/agentbox and its stamps"
  echo "  git-guard (~/.local/bin/git), ~/.config/environment.d/agentbox.conf"
  echo "  ~/.local/bin/agentbox, its bash completion and $INSTALL_DIR"
  if [[ -n "$all" ]]; then
    echo "  --all: the Podman secrets agentbox uses (tokens), and your files in $AB_HOME_DIR"
    echo "    (config.toml, env/ with passwords, skills)"
  fi
  if ! ask "remove all this?"; then echo "agentbox: nothing removed"; return 0; fi
  if [[ -n "$all" ]] || { [[ -z "$yes" ]] && ask "also the Podman secrets (tokens) agentbox uses?"; }; then secrets_too=1; fi
  if [[ -n "$all" ]] || { [[ -z "$yes" ]] && ask "also your files in $AB_HOME_DIR (config.toml, env/ with passwords, skills)?"; }; then files_too=1; fi

  if command -v systemctl >/dev/null; then
    for c in $(host_units_list | awk '{ print $1 }'); do
      systemctl --user stop "$c" >/dev/null 2>&1 && echo "stopped host service $c"
    done
  fi
  # Containers first: networks and volumes in use cannot go.
  for c in $(podman ps -a --format '{{.Names}}' 2>/dev/null | awk '{ print $1 }' | grep '^ab-'); do
    podman rm -f -v "$c" >/dev/null && echo "removed container $c"
  done
  for n in $(podman network ls --format '{{.Name}}' 2>/dev/null | grep '^ab-'); do
    # Your own containers (AB_SERVICES) are disconnected, never removed:
    # network rm -f would remove them.
    for c in $(podman network inspect "$n" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
      podman network disconnect "$n" "$c" >/dev/null 2>&1 && echo "disconnected $c from $n"
    done
    podman network rm "$n" >/dev/null && echo "removed network $n"
  done
  for v in $(podman volume ls --format '{{.Name}}' 2>/dev/null | grep '^ab-'); do
    podman volume rm "$v" >/dev/null && echo "removed volume $v"
  done
  # Replaced images kept for a session that still ran on them: their record
  # goes with the cache below.
  while read -r _ id; do
    [[ -n "${id:-}" ]] && podman rmi "$id" >/dev/null 2>&1 && echo "removed image $id (replaced earlier)"
  done < <(cat "${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/retired-images" 2>/dev/null)
  # Also the images modules build here (mcp/bb4), by their agentbox.build label.
  for v in "$IMAGE" "$IMG_SQUID" "$IMG_NGINX" $(uninstall_names MCP_IMAGES) $(mcp_uninstall_names images) \
           $(podman images --filter label=agentbox.build --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^localhost/agentbox-'); do
    podman image exists "$v" 2>/dev/null && podman rmi "$v" >/dev/null 2>&1 && echo "removed image $v"
  done
  if [[ -n "$secrets_too" ]]; then
    uninstall_config config_values && config=config_values
    for v in claude_oauth openai_api_key llm_openai_caller $(uninstall_names MCP_SECRETS) $(uninstall_names MCP_OWN_SECRETS) \
             $(uninstall_names MCP_CALLER_SECRET) $(uninstall_secrets_by_setting $config) $(mcp_uninstall_names secrets $config); do
      podman secret inspect "$v" >/dev/null 2>&1 && podman secret rm "$v" >/dev/null && echo "removed secret $v"
    done
  fi

  cache="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox"
  if [[ -n "$secrets_too" || ! -d "$cache/modules" ]]; then
    rm -rf -- "$cache"
  else
    # The index of the modules has the for_each names that agentbox made:
    # a later agentbox uninstall --all needs them.
    find "$cache" -mindepth 1 -maxdepth 1 ! -name modules ! -name modules.lock -exec rm -rf -- {} +
    echo "kept $cache/modules: the names of the secrets that agentbox made, for agentbox uninstall --all"
  fi
  rm -f -- "${XDG_CACHE_HOME:-$HOME/.cache}"/agentbox.*
  if grep -qs 'agentbox git-guard' "$HOME/.local/bin/git"; then
    rm -f -- "$HOME/.local/bin/git" && echo "removed git-guard; git is the system's again"
  fi
  # Only the file agentbox wrote; one of your own (made by hand from an
  # older README) stays.
  if [[ -f "$ENVIRONMENT_FILE" ]]; then
    # Exactly as agentbox wrote it: with lines of yours added, it stays.
    if [[ "$(cat -- "$ENVIRONMENT_FILE")" == "$(release_environment_content)" ]]; then
      rm -f -- "$ENVIRONMENT_FILE"
    else
      echo "kept $ENVIRONMENT_FILE: not as agentbox wrote it; remove it yourself if it is only for agentbox"
    fi
  fi
  [[ -L "$HOME/.local/bin/agentbox" ]] && rm -f -- "$HOME/.local/bin/agentbox"
  [[ -L "$COMPLETION_LINK" ]] && rm -f -- "$COMPLETION_LINK"
  if [[ -d "$INSTALL_DIR" ]]; then
    chmod -R u+w -- "$INSTALL_DIR"
    rm -rf -- "${INSTALL_DIR:?}"
    echo "removed $INSTALL_DIR"
  fi
  if [[ -n "$files_too" ]]; then
    rm -rf -- "${AB_HOME_DIR:?}"
    echo "removed $AB_HOME_DIR"
  else
    echo "kept $AB_HOME_DIR; remove it with: rm -rf '$AB_HOME_DIR'"
    [[ -n "$secrets_too" ]] || echo "kept the Podman secrets; list them with: podman secret ls"
  fi
  echo "agentbox: uninstalled. Settings from environment.d last until you log in again."
}
