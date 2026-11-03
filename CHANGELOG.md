# Changelog

Each release has a section here; `agentbox update` shows it before you
confirm, and `release.sh` refuses a version without one. Under "Action" go
the steps a release needs from you, such as a rebuild.

## v0.1.11

- bb4: the server for the browser's pages is now `bb4-devtools`, not
  `chrome-devtools`, the name chrome-devtools-mcp's own instructions give
  a registration by hand.
- A module's server marked `caller` without an `MCP_CALLER_SECRET`, or two
  servers with the same name, leave that module out of the start with the
  reason, instead of failing quietly in the session. So do a module whose
  mcp.sh sets no `MCP_URL` (its URL may come from its settings; emptied,
  its sidecars go) and one whose mcp.sh does not parse, which both stopped
  the whole start before.
- `agentbox setup` shows "NOT USABLE" and the reason under a module that
  the start would leave out: a setting that is not correct, or a fault in
  its server lines. It says so when you enable the module, too.
- Modules check their settings in a new optional `mcp_check`, which the
  start and `agentbox setup` both run. A setting of woodpecker or tabularis
  that is not correct now removes what the module runs, as bb4 already
  did and as an emptied setting does. Before, open sessions kept it. A
  module left out for a setting or secret is removed at once, not at the
  end of the start.
- The warnings of the update check (an image or skill source that could
  not be updated, a skill record that is not correct) are in the list
  before the session too. "Could not check" is not: offline, it would ask
  at every start.
- When `dbhub.toml` is refused, the warning gives the reason, not "see the
  output above".
- The update check also reminds you when the base of an image that a
  module builds here (bb4's `agentbox-bb4-devtools`) is a month old.
- A module in `AB_MCP` that this version does not have keeps only the
  sidecars that carry its mark, not all of those with its name prefix.
- A module whose mcp.sh does not parse adds no "unknown key" warnings for
  its settings.
- When podman cannot start a module's sidecar, its `Error:` line is the
  reason in the warning before the session.
- `agentbox uninstall` also finds the images of a module of yours whose
  `MCP_IMAGES` or image variable is indented or in single quotes.
- Fewer podman calls per start: the agentbox image ID is looked up once.
  The bb4 devtools image is built again once (its fingerprint is now
  made like those of the other images).

Action: rename `mcp__chrome-devtools__` to `mcp__bb4-devtools__` in
permission rules (`.claude/settings*.json`) and anything else that names
bb4's page tools.

## v0.1.10

- New MCP module `bb4`: a remote browser on a browser server, one per
  user, that the agent drives. Two servers: `bb4`, the server's own (start
  and set up the browser), and `chrome-devtools` (open pages, read, click,
  type, screenshots), chrome-devtools-mcp in a sidecar built here from
  pinned packages, without usage statistics or CrUX. Settings `BB4_URL`,
  `BB4_USER`, `BB4_DEVTOOLS_PORT`. The browser reaches the whole internet
  past squid's allowlist, so every start warns in capitals while it is on.
  See README, Remote browser (bb4).
- A module can register more than one MCP server (`MCP_SERVERS`).
- A module in `AB_MCP` that this version does not have (one of a newer or
  older version, or a typo) is left out with a warning, like a module that
  cannot run, instead of stopping the start; sidecars of it that another
  version runs stay. Only a name that is not one
  (`../etc`) still stops it.
- Tabularis bridge: `@modelcontextprotocol/node` 2.1.0 and
  `@hono/node-server` 2.1.3 under supergateway, for a vulnerability in not
  limiting the size of a request (GHSA-f897-62hf-6gxq). `@hono/node-server`
  2.x goes past the range `@modelcontextprotocol/node` declares (^1); the
  SDK itself accepts it, and both bridges were checked with it. The first
  start with tabularis installs the bridge anew (the npm registry once).

## v0.1.9

- Faster start: a sidecar that needs no change costs two podman calls
  instead of five, the Podman secrets are listed with one podman call
  (twice per start) instead of checked one by one, and the dbhub module parses `dbhub.toml` in a
  container only when it, the module or the agentbox image changed.
- An MCP module that cannot run no longer stops the start: one without its
  settings or secrets, or whose start fails (a bad `WOODPECKER_URL`, a
  refused `dbhub.toml`, the Tabularis bridge failing to install), is left
  out of that session with a warning saying why, and the session starts
  with the other modules. If its start failed, what the module already
  runs stays for the sessions using it, unless that start had already
  replaced it, or the error means access should go (a deleted
  `dbhub.toml`, a woodpecker network that is not `--internal`, another
  program on the Tabularis port). A module without its setting or secret
  loses its sidecars, as one taken out of `AB_MCP` does: deleting a
  token's secret takes the access away. A module's sidecars, their cache
  copies and its host services carry its name as a mark
  (`agentbox.module`), and are kept or removed by that, never by a name
  that only starts like another's.
- README, GitHub (MCP): a token that can write Contents, or a classic
  token, lets the agent commit on GitHub around your local git; how to
  check yours.
- The warnings of a start scrolled away under the agent's screen. At a
  terminal, agentbox now lists them again right before the session and
  asks whether to start it (Enter: yes). No question without a terminal,
  with `-p`/`--print`, for `agentbox shell` with a command, or with
  `AB_WARNINGS_ASK=0` in `config.env`.

Action: none. The first start after the update recreates the MCP
sidecars once and restarts the Tabularis bridge once (they get the
mark).

## v0.1.8

- New MCP module `dbhub`: SQL databases you list in
  `~/.config/agentbox/dbhub.toml`, read only, through `bytebase/dbhub`. The
  agent searches schemas and runs queries; agentbox gives each database a
  read-only `execute_sql`. DBHub never reads your file: agentbox parses it
  and writes DBHub's config from the sources alone, and refuses anything
  else there. The passwords stay out of the session. See README, DBHub
  (MCP).
- A sidecar's copies in the cache go when its module is turned off.
- `agentbox uninstall` also removes the images of the woodpecker and dbhub
  modules, which it missed (a module names its image through a variable).

## v0.1.7

- New MCP module `woodpecker`: Woodpecker CI's repositories, pipelines,
  step logs and configs, read only, through `rtuszik/woodpecker-mcp`. The
  Woodpecker token stays in nginx, which lets the server read only (GET
  and HEAD); the server is on an --internal network of its own with nginx,
  without squid or outside DNS. See README, Woodpecker (MCP).
- A sidecar is recreated when a Podman secret it holds is made anew: a
  token renewed with `e <number>` in `agentbox setup` takes effect at the
  next start, without `AB_RESTART=1`. The first start after the update
  recreates every sidecar that holds a secret once.
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
