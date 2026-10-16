# Changelog

Each release has a section here; `agentbox update` shows it before you
confirm, and `release.sh` refuses a version without one. Under "Action" go
the steps a release needs from you, such as a rebuild.

## v0.1.0

The first release.

- Claude Code, pi or a plain shell (`agentbox shell`) in a rootless Podman
  box: internal network only, no host credentials, no capabilities, read-only
  agent binary, external DNS cut off.
- Egress only through squid, by host groups (`AB_EGRESS`, `egress.d/`,
  `~/.config/agentbox/egress.local.d/`).
- Squid built here from Debian (`Containerfile.squid`), not pulled: its
  packages follow `AB_UPGRADE=1`; the update check reminds when the
  agentbox and squid images are a month old.
- MCP servers as modules (`AB_MCP`): context7, grafana, graylog, github.
  Tokens stay in sidecars; the agents send per-module caller tokens.
- Skill sources (`AB_SKILLS`, `skills.d/`), vendored with a prefix, no
  symlinks; update check every 6 hours (`check-updates.sh`).
- Local dev containers (`AB_SERVICES`) and services outside the box
  (`AB_FORWARD`, globally or per repository).
- Your files apart from the code, in `~/.config/agentbox/`.
- Trivy in the box (`AB_TRIVY=1`), its database fetched outside the session;
  CI reports fixable HIGH/CRITICAL issues in agentbox's images daily.
- `git-guard`: host git refuses repositories whose `.git` a session
  redirected (README, Git on the host).
- `agentbox login`: the Claude Code token through a browser sign-in in the
  box, also offered at the first start without one.
- Installation and signed updates: `install.sh`, `agentbox update`,
  `agentbox rollback`; `agentbox uninstall` removes it all again.
- Checks: `tests/run.sh` with a podman stand-in and real git attacks;
  `tests/escape.sh` inside a real box, also in CI.

Action: from a clone used before, move your files as `run.sh` tells you
(README, Your files), then install `git-guard` (README, Git on the host).
