# Changelog

Each release has a section here; `agentbox update` shows it before you
confirm, and `release.sh` refuses a version without one. Under "Action" go
the steps a release needs from you, such as a rebuild.

## v0.1.7

- pi with a ChatGPT subscription stopped with "EACCES ... models.json" when
  it had once run with an API key: the mount of models.json had left an
  empty, root-owned file in pi's home volume, which pi then read in its
  place. The files a session may get (pi's models.json and AGENTS.md,
  Claude Code's CLAUDE.md and status line) are now always mounted, a
  neutral one when there is nothing to put there (models.json without
  overrides, an empty AGENTS.md), so no leftover is ever read.
  Without `~/.config/agentbox/AGENTS.md`, Claude Code's `~/.claude/CLAUDE.md`
  in its volume (written by `/memory` or `#` notes) is now covered by an
  empty read-only file, and so is a `models.json` in pi's volume in
  subscription mode: instructions for every session go in AGENTS.md.
  agentbox warns at each start while such a file of yours is there, with
  the commands to read and remove it.

## v0.1.6

- `fd` in the image (Debian's `fd-find`): pi uses it for file search and
  warned "fd not found" at every start.
- pi in API-key mode failed in an installed version with "EACCES ... models.json",
  and Claude Code's status line was not shown: both files were mounted from
  the read-only installed code, which podman cannot relabel for SELinux.
  Sessions now mount copies from `$XDG_CACHE_HOME/agentbox/session/`
  (default `~/.cache`).
- Every start prints which agentbox runs: `agentbox v0.1.6`, or
  `agentbox dev (<path>)` from a clone.
- `agentbox update` shows the changes of every release it brings, skipped
  ones included, newest first. (The update to v0.1.6 itself still runs the
  older code and shows only this section.)

Action: none. The first start after the update rebuilds the agentbox image
once, a few minutes.

## v0.1.5

- `agentbox setup`: a menu for `config.env`. It turns MCP modules, skill
  sources, egress groups and Trivy on and off, shows each module's settings
  and secrets, asks for them (hidden for secrets, which `e <number>` also
  replaces, for a renewed token), and edits the file in place (comments
  kept, the old one as `config.env.bak`). Tab completes it too.
- Modules can say what to type for a secret (`MCP_SECRET_HELP`) and how to
  store it (`mcp_secret_value`); graylog turns the token into its basic-auth
  value.
- Tabularis bridge: supergateway and every package under it come from
  `mcp/tabularis/bridge/package-lock.json`, installed with
  `npm ci --ignore-scripts`: npm checks each package against its hash, and
  no package's install script runs on your host. Before, `npx` resolved the
  dependencies itself at the first start.
- The MCP SDK packages supergateway pins are replaced with releases that
  fix vulnerabilities, two of them in serving several sessions at once.
- If the install fails (no npm registry, say), the start stops and says to
  take `tabularis` out of `AB_MCP` to start without it.

Action: none needed. The first start with `tabularis` installs the bridge
(Node.js with npm on the host, and the npm registry once) and restarts it.
`npx` is no longer used: its cache of the old, unpinned tree can go with
`rm -rf ~/.npm/_npx`.

## v0.1.4

- New MCP module `tabularis`: the database connections saved in the
  Tabularis desktop app, through its built-in MCP server. Passwords stay on
  the host; Tabularis's read-only mode and write approvals apply. It runs a
  bridge on the host (supergateway, as a transient systemd user service) and
  needs Node.js there. See README, Tabularis (MCP).
- Modules can run a program on the host with `start_host_unit`, and name
  secrets they create in `MCP_OWN_SECRETS`. `agentbox uninstall` stops such
  services and, with `--all`, removes those secrets.

## v0.1.3

- With git-guard, agentbox writes `~/.config/environment.d/agentbox.conf`
  (`~/.local/bin` first in `PATH` for the whole desktop session, editors
  included; `core.fsmonitor` off for any git): at install, and at the next
  start of an installed version that has git-guard but not the file. Once
  per installation: delete it to do without. A file that is there is never
  changed, and uninstall removes only the one agentbox wrote.
- README: the install steps find the latest release themselves.

Action: if agentbox says it wrote the environment.d file, log out and back
in.

## v0.1.2

- Tab completion for `agentbox` in bash (`completions/agentbox.bash`),
  linked at install and at every update.
- README: copying out of a session (OSC 52, kitty).
- Sidecars follow their image: squid after a rebuild (v0.1.1 rebuilds it
  once) and MCP images after a pull, without `AB_RESTART=1`.
- `agentbox login` on podman before 4.7 (no `secret create --replace`), and
  without building the squid image it does not use. A token pasted over
  several lines is kept whole; with another `AB_AGENT` it says which.
- `agentbox update`: a release missing a file is reported, not a silent
  exit; the download is removed after a failure; an install interrupted
  earlier no longer breaks the next one.
- `release.sh` deletes its tag again when it stops before the tag is
  pushed.
- `run.sh` refuses to mount the other installed versions (`agentbox
  rollback` would run code a session changed) and git-guard's directory.
- `install.sh` never puts git-guard over a `~/.local/bin/git` of your own.
- `agentbox update` and the update check no longer offer an older release
  as an update.
- The `docker.io/ubuntu/squid` image goes when an `ab-egress` still on it
  moves to the local squid; one that is merely there, maybe yours, stays.
  `agentbox uninstall` also removes images replaced earlier that a session
  still held, and with `--all` names the secrets and files it removes.
- The month-old reminder for the agentbox and squid images counts from the
  last build that pulled the base image, not from any rebuild.
- Trivy: a removed `ab-trivy` volume is filled again at the next start.

Action: open a new terminal tab after the update for Tab completion.

## v0.1.1

- Images rebuilt when their `Containerfile` or build settings change:
  a changed `AB_TRIVY`, `AB_PYTHON_VERSIONS`, `AB_GO_VERSION`,
  `AB_GOLANGCI_LINT_VERSION` or `AB_GRAPHIFY_EXTRAS` applies at the next
  start, no `AB_UPGRADE=1` needed. Each image carries a fingerprint of what
  it was built from (label `agentbox.build`).
- git-guard skips any copy of itself when it looks for the real git: with
  two copies in PATH (an installed one and another) each called the other
  forever. Hit by `tests/run.sh` on a host with git-guard installed.
- README: an Uninstall section; release, license and platform badges.

Action: none. The first start after the update rebuilds the agentbox and
squid images once (images from v0.1.0 have no fingerprint), a few minutes.

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
