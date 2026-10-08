#!/usr/bin/env bash
# agentbox: run the pi coding agent in the same isolated box as Claude Code.
# Same arguments as run.sh; see README "pi".
exec env AB_AGENT=pi "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/run.sh" "$@"
