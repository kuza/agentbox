# bash completion for the agentbox command. agentbox links it as
# ~/.local/share/bash-completion/completions/agentbox, where bash-completion
# finds it (lib/release.sh, release_sync_completion).
#
# First word: agentbox's commands and directories (the repo). After pi or
# shell: a directory. After update and uninstall: their options. After a
# repo, the words go to the agent: file names, as bash completes them anyway.

_agentbox() {
  local cur="${COMP_WORDS[COMP_CWORD]}" first="${COMP_WORDS[1]:-}"
  local -a words=()
  COMPREPLY=()
  if (( COMP_CWORD == 1 )); then
    compopt -o filenames 2>/dev/null
    mapfile -t words < <(compgen -W "pi shell login version update rollback uninstall" -- "$cur"; compgen -d -- "$cur")
  else
    case "$first" in
      pi|shell)
        if (( COMP_CWORD == 2 )); then
          compopt -o filenames 2>/dev/null
          mapfile -t words < <(compgen -d -- "$cur")
        else
          compopt -o default 2>/dev/null
        fi ;;
      update) mapfile -t words < <(compgen -W "--yes" -- "$cur") ;;
      uninstall) mapfile -t words < <(compgen -W "--yes --all" -- "$cur") ;;
      login|version|rollback) ;;
      *) compopt -o default 2>/dev/null ;;
    esac
  fi
  COMPREPLY=("${words[@]}")
}
complete -F _agentbox agentbox
