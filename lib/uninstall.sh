# agentbox uninstall: removes what agentbox put on this host.
#
#   agentbox uninstall            shows the list and asks; asks separately
#                                 about Podman secrets and your files
#   agentbox uninstall --yes      without asking; keeps secrets and your files
#   agentbox uninstall --yes --all  everything, secrets and your files too
#
# Removed: containers, volumes and networks named ab-* (open sessions end;
# your own containers attached to ab-services are only disconnected, never
# removed), agentbox's images, the cache, git-guard (~/.local/bin/git, if it
# is git-guard), ~/.config/environment.d/agentbox.conf, the agentbox command
# with its bash completion, and the installed versions. Secrets: those
# agentbox and its modules use.
# Your files: <AB_HOME> (config.env, env/ with passwords, skills, ...).
# Needs SCRIPT_DIR, lib/paths.sh, lib/release.sh and IMG_* from lib/config.sh.

# Values of an MCP_ variable in all modules, read as text, not run: names
# like grafana_sa or images like ghcr.io/x/y:tag ("$IMG_NGINX" is left out,
# agentbox_uninstall removes it anyway).
uninstall_names() {  # <MCP_ variable>
  local f
  for f in "$SCRIPT_DIR"/mcp/*/mcp.sh "$USER_MCP_DIR"/*/mcp.sh; do
    [[ -f "$f" ]] || continue
    sed -n "s/^$1=//p" "$f"
  done | tr -d '()"' | tr ' ' '\n' | grep -E '^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$' | sort -u
}

agentbox_uninstall() {
  local yes="" all="" reply secrets_too="" files_too="" a c v n id
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
  echo "  images: localhost/agentbox and the sidecar images"
  echo "  ${XDG_CACHE_HOME:-$HOME/.cache}/agentbox and its stamps"
  echo "  git-guard (~/.local/bin/git), ~/.config/environment.d/agentbox.conf"
  echo "  ~/.local/bin/agentbox, its bash completion and $INSTALL_DIR"
  if [[ -n "$all" ]]; then
    echo "  --all: the Podman secrets agentbox uses (tokens), and your files in $AB_HOME_DIR"
    echo "    (config.env, env/ with passwords, skills)"
  fi
  if ! ask "remove all this?"; then echo "agentbox: nothing removed"; return 0; fi
  if [[ -n "$all" ]] || { [[ -z "$yes" ]] && ask "also the Podman secrets (tokens) agentbox uses?"; }; then secrets_too=1; fi
  if [[ -n "$all" ]] || { [[ -z "$yes" ]] && ask "also your files in $AB_HOME_DIR (config.env, env/ with passwords, skills)?"; }; then files_too=1; fi

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
  for v in "$IMAGE" "$IMG_SQUID" "$IMG_NGINX" $(uninstall_names MCP_IMAGES); do
    podman image exists "$v" 2>/dev/null && podman rmi "$v" >/dev/null 2>&1 && echo "removed image $v"
  done
  if [[ -n "$secrets_too" ]]; then
    for v in claude_oauth openai_api_key llm_openai_caller $(uninstall_names MCP_SECRETS) $(uninstall_names MCP_CALLER_SECRET); do
      podman secret inspect "$v" >/dev/null 2>&1 && podman secret rm "$v" >/dev/null && echo "removed secret $v"
    done
  fi

  rm -rf -- "${XDG_CACHE_HOME:-$HOME/.cache}/agentbox"
  rm -f -- "${XDG_CACHE_HOME:-$HOME/.cache}"/agentbox.*
  if grep -qs 'agentbox git-guard' "$HOME/.local/bin/git"; then
    rm -f -- "$HOME/.local/bin/git" && echo "removed git-guard; git is the system's again"
  fi
  rm -f -- "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/agentbox.conf"
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
