#!/usr/bin/env bash
# install.sh: install agentbox from an unpacked release (agentbox-vX.Y.Z/),
# on the HOST. Later versions come with `agentbox update`.
#
#   ./install.sh [--git-guard]
#
# Puts this release into ~/.local/share/agentbox/versions/<version>/
# (read-only; AB_INSTALL_DIR moves it), makes it the current version, links
# ~/.local/bin/agentbox to it, and creates ~/.config/agentbox/config.env from
# the example if you have none. --git-guard also installs git-guard as
# ~/.local/bin/git and ~/.config/environment.d/agentbox.conf, which puts it
# first in PATH (README, Git on the host); without it, you are asked.
#
# From a clone (no release version in VERSION) it refuses: run ./run.sh there
# for development, or install a release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"

guard=""
[[ "${1:-}" == --git-guard ]] && guard=1

version="$(agentbox_version)"
if [[ "$version" == dev ]]; then
  echo "error: $SCRIPT_DIR is a clone, not a release; download a release" \
       "(README, Quick start) or run ./run.sh here for development" >&2
  exit 2
fi
if release_installed; then
  echo "error: run install.sh from an unpacked release, not from an installed version" >&2
  exit 2
fi

release_place "$SCRIPT_DIR" "$version"
release_switch "$version"

mkdir -p "$HOME/.local/bin"
ln -sfn "$INSTALL_DIR/current/agentbox" "$HOME/.local/bin/agentbox"
echo "agentbox: command ~/.local/bin/agentbox"

mkdir -p "$AB_HOME_DIR"
if [[ ! -e "$USER_CONFIG" ]]; then
  cp "$SCRIPT_DIR/config.env.example" "$USER_CONFIG"
  echo "agentbox: created $USER_CONFIG from the example; edit it (README, Quick start)"
fi

gitbin="$HOME/.local/bin/git"
if [[ ( -e "$gitbin" || -L "$gitbin" ) ]] && ! grep -qs 'agentbox git-guard' "$gitbin"; then
  # Your own git or wrapper there: never replaced.
  [[ -n "$guard" || -t 0 ]] && echo "agentbox: ~/.local/bin/git is not git-guard; left as it is." \
    "To use git-guard (README, Git on the host), move it away, then:" \
    "install -m 755 '$INSTALL_DIR/current/git-guard' ~/.local/bin/git"
  guard=""
elif [[ -z "$guard" && -t 0 ]] && ! grep -qs 'agentbox git-guard' "$gitbin"; then
  read -r -p "agentbox: install git-guard as ~/.local/bin/git (README, Git on the host)? [Y/n] " reply || reply=n
  [[ "$reply" == [nN]* ]] || guard=1
fi
if [[ -n "$guard" ]]; then
  install -m 755 "$INSTALL_DIR/current/git-guard" "$HOME/.local/bin/git"
  echo "agentbox: git-guard installed as ~/.local/bin/git"
  release_sync_environment
fi

# The environment.d file puts it there from the next login on.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) [[ -e "$ENVIRONMENT_FILE" ]] \
       || echo "agentbox: add ~/.local/bin to PATH, ahead of /usr/bin (README, Git on the host)" ;;
esac
echo "agentbox: $version installed. Next: README, Quick start, step 2."
