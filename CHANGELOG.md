# Changelog

Each release has a section here; `agentbox update` shows it before you
confirm, and `release.sh` refuses a version without one. Under "Action" go
the steps a release needs from you, such as a rebuild.

## v0.2.2

- An agent that stops or crashes can keep terminal modes on, for example
  mouse reports, bracketed paste or application keys. Now agentbox resets
  these modes and shows the cursor after the container of a session or of
  `agentbox login` stops. It does this only at a terminal and does not
  clear the screen. The exit status of the session does not change.

## v0.2.1

- Each shared MCP module has a manifest, `module.toml`: its description,
  settings, secrets, servers, images and egress hosts, as data. `mcp.sh`
  keeps only the code of a module. context7 has no `mcp.sh`. README,
  "Writing a module", describes the format, and "Converting a module"
  shows how to convert a module of the old format.
- Your settings files do not change. The settings of v0.2.0 work as they
  are: a port as a string or a number, and a list as an array or as a
  string with spaces or commas.
- A module of the old format (only `mcp.sh`) in `mcp.local/` still works.
  Each start shows a warning for it while it is enabled. A module with a
  `module.toml` and old `MCP_*` variables in its `mcp.sh` is left out with
  the reason.
- The modules check their settings with five built-in checks (`url`,
  `url-base`, `port`, `name`, `file`). All modules give a failed check in
  one message form: `<place>: <KEY>: <reason> (<check>)`. The place is the
  file and the line of the value (`config.toml:12`), `environment`, or the
  line of a default in `module.toml`. The start shows only the first failed
  setting of a module. The message of a list setting does not name the bad
  item.
- The checks refuse some values that v0.2.0 took. A module with such a
  value is left out, agentbox removes what it runs, and `agentbox setup`
  shows "NOT USABLE":
  - `GRAFANA_URL` and `GRAYLOG_URL` (no check before): a query
    (`?orgId=1`, which Grafana adds to browser URLs), a fragment (`#...`),
    `user@` in the host part, `@` in the path, `_` in a host, a scheme in
    uppercase, a host that ends with `.`, an IPv6 host, a port with a `0`
    at the start, a port above 65535 or an empty port, and a character in
    the path other than letters, digits and `. _ ~ : / % + = , ! * -`.
  - `WOODPECKER_URL`: a character other than a letter, a digit, `-` or `.`
    in the host (such as `_`); a host label with `-` at the start or the
    end; an empty label (`ci..example`, a host that ends with `.`); a port
    above 65535, with a `0` at the start, empty or not digits; a second
    `:` in the host part; no host.
  - `WOODPECKER_CA`: a missing or unreadable file now leaves the module
    out and removes its sidecars. In v0.2.0, the start of the module
    stopped, and open sessions kept the sidecars.
  - `BB4_USER`: a `-` at the end, `--`, and more than 39 characters.
  - `GH_TOOLSETS`: a toolset with a character other than `a-z` and `_`,
    and a value of only commas or spaces.
- `GH_TOOLSETS` is a list setting. Spaces and commas separate the
  toolsets, and nginx gets them joined with a comma, each once:
  `"repos issues"` and `"repos, issues"` become `repos,issues`.
- `GH_OWNERS`: a tab between names separates the names. A bad name
  gives the message of the `name` check, not the list of the bad names.
- `agentbox setup` shows the help of a setting when it asks for the value.
  It writes a list setting of a module as an array (`GH_OWNERS = ["acme"]`,
  `GH_TOOLSETS`).
- `agentbox uninstall` finds the images and secrets of the modules in an
  index: `mcp/<name>/module.index` of the release, and a file in
  `~/.cache/agentbox/modules/` that each start writes. `agentbox setup`
  adds the owner tokens that it stores.
  Uninstall without Python now removes them too. It removes each
  `github_pat_<owner>` that a start or `agentbox setup` of v0.2.1 or later
  used, also for an owner that you removed from `GH_OWNERS`. If it cannot
  read a manifest or `config.toml`, it removes only the owner tokens of
  the index, and says so. Without Python, it cannot read `config.toml`.
  The same is true when one owner in `config.toml` is bad. If it cannot
  find the names of a module at all, it says so too. If you keep the
  secrets, uninstall keeps `~/.cache/agentbox/modules`. An
  `agentbox uninstall --all` of a new install or a clone uses it.
- `agents/AGENTS.md.example` has a new section "Services and forwards".
  It tells the agent to look for the services of the box before it
  installs its own database or queue.

Action:

- If you have your own `~/.config/agentbox/AGENTS.md`, copy the section
  "Services and forwards" from `agents/AGENTS.md.example` into it.
- If you have modules in `mcp.local/`, convert them to `module.toml`
  before v0.3.0, which removes the old format. README, "Converting a
  module", shows the steps.
- v0.2.0 cannot run a module with a `module.toml`. Before
  `agentbox rollback` to v0.2.0, move the converted modules and the copies
  of shared modules out of `mcp.local/`.
- If a check now refuses a value of yours, the start names the setting.
  Correct the value in `config.toml`.

## v0.2.0

- Your settings are in `config.toml`, a flat TOML file, not in
  `config.env`. A list is an array (`AB_MCP = ["grafana", "bb4"]`), a flag
  is `true` or `false`, and a number has no quotes. The settings of one
  repository are in `env/<repo>.toml`, in the same form. `env/<repo>.env`
  does not change. `config.toml.example` replaces `config.env.example`.
- An environment variable still overrides a setting. In the environment, a
  list is a string with spaces or commas (`AB_MCP="grafana bb4"`).
- agentbox refuses a float, a date, a table, a quoted key and a multi-line
  string, with the file and the line. Put versions in quotes:
  `AB_PYTHON_VERSIONS = ["3.12", "3.13"]`. A key that agentbox and the
  enabled modules do not know gets a warning with its line. The settings
  of a module that is not enabled get no warning.
- Skill sources, pi extension sources and egress groups are `.toml` files
  with lowercase keys and arrays:
  - a skill source: `url`, `only`, `prefix`, `ref`, `subdir`;
  - a pi extension source: `url`, `ref`, `needs_skills`;
  - an egress group: `hosts`. A host can have a comment on its line.

  An unknown key, or a missing `url` (`hosts` in a group), is an error,
  with its line.
- The first start, or `agentbox setup`, converts your files one time:
  - `config.env`, or the `.env` file of `AB_CONFIG`;
  - `env/<repo>.conf`;
  - the `.conf` files in `skills.local.d/`, `pi-extensions.local.d/` and
    `egress.local.d/`.

  The start names each converted file. In a source, a key that the new
  format does not know becomes a comment, with a warning. In the settings
  files, each key stays a setting. A flag or a number with a wrong value,
  a line that is not `KEY=VALUE` and a second line of the same key become
  a comment, with a warning. `converted.list` in `~/.config/agentbox`
  (`AB_HOME`) lists the converted files. To convert a file again, remove
  its line from the list (README, "Conversion to TOML").
- While a `.conf` file of yours is not converted, agentbox does not use
  the shared file of the same name in its place.
- The conversion reads a skill or pi extension source with the parser of
  `config.env`. This parser removes quotes, `export ` and a ` # note` at
  the end, and it reads an indented line. The parser of sources in v0.1.x
  did not. If your `.conf` had such a line, agentbox now uses its value
  (an indented `REF=v1` now pins the source), and the first start syncs
  that source one more time.
- `agentbox setup` edits `config.toml` line by line. It keeps your
  comments and the order of the lines. It does not change a key whose
  value is on more than one line, and says why. It no longer writes
  `config.env`.
- agentbox needs Python 3.11 or newer on the host to start a session and
  to run `agentbox setup`. `install.sh` checks for it and tells you how to
  install it. `agentbox update`, `rollback` and `uninstall` work without
  it. Without it, `agentbox uninstall --all` cannot read `GH_OWNERS`: it
  keeps the `github_pat_<owner>` secrets and says so.
- The conversion uses `flock` (util-linux), so that only one start
  converts at a time.

Action:

- Read the converted files that the first start or `agentbox setup`
  names. The old files stay unchanged until v0.3.0, for
  `agentbox rollback`. After a rollback, v0.1.x reads only the old files,
  and v0.2.0 reads only the TOML files.
- If you do not have Python 3.11 or newer, install it before the update.
  README, "Requirements", gives the package for Fedora, RHEL 9 and
  Ubuntu 22.04.
- If `AB_CONFIG` names a `.env` file, change it to the `.toml` file next
  to it after the first start. Before a rollback, set it back to the
  `.env` file: v0.1.x cannot read a TOML file.
- If `AB_CONFIG` names a file without `.env`, do these steps before the
  first start:
  1. Copy the file to a name with the `.env` extension.
  2. Set `AB_CONFIG` to the copy.

## v0.1.14

- The settings of a module that is not enabled (for example, bb4 was
  configured and then removed from `AB_MCP`) no longer give "unknown key"
  warnings in `config.env`. agentbox ignores them. A key that no module
  has still gives the warning.

## v0.1.13

- New shared sources for ponytail (DietrichGebert/ponytail), a "lazy
  senior dev" prompt. The skill source `ponytail` gives both agents the
  skill and `/ponytail-review`, `/ponytail-audit` and other commands.
- The pi extension `ponytail` adds the rules at each turn of pi, with
  `/ponytail lite|full|ultra|off`. Its commands call the skills, so enable
  both sources for pi. agentbox does not enable them by default.
- A skill source can set `SUBDIR`: the directory in its repository where
  agentbox looks for skills. Use it for a repository that also keeps copies
  of its skills for other agents, as ponytail does.
- A pi extension source can set `NEEDS_SKILLS`. The start of pi says so
  when such a skill source is not in `AB_SKILLS`. The ponytail extension sets
  it.
- A disabled pi extension whose install stopped before its record is
  removed too.
- github: more resource owners. A fine-grained token has one owner, so
  `GH_OWNERS` lists the others. Each owner gets its token
  `github_pat_<owner>` and the MCP server `github-<owner>`. The same nginx
  serves them and keeps the tokens. `agentbox setup` asks for the tokens.
  `agentbox uninstall --all` removes the tokens of the owners in
  `config.env`, and no other secret with that prefix.

## v0.1.12

- pi extensions from git. The sources are in `pi-extensions.d/` (shared:
  `pi-subagents`, `pi-prompt-history`) or in `pi-extensions.local.d/`
  (yours). Enable them with `AB_PI_EXTENSIONS` or in `agentbox setup`.
- The next start of pi installs them on the host with
  `sync-pi-extension.sh`. It makes a new clone and checks that it is an
  extension. For dependencies, it runs `npm ci` without scripts, and it
  accepts only packages from the npm registry. This needs npm on the host.
- The update check offers new commits of an extension. It installs them
  only when you answer yes. An extension that you put into
  `pi-extensions/` yourself stays as it is.
- A skill source or a pi extension source with a `REF` that names a branch
  works now. Before, the sync failed for a branch; a tag or a commit
  worked.

## v0.1.11

- bb4: the server for the pages of the browser is now `bb4-devtools`, not
  `chrome-devtools`. The old name is the name that the instructions of
  chrome-devtools-mcp give for a server that you register yourself.
- These module faults leave the module out of the start, with the reason:
  a server marked `caller` without an `MCP_CALLER_SECRET`, two servers
  with the same name, a server or module without a URL, and an mcp.sh
  that does not parse. Before, the first two failed quietly in the
  session, and the last two stopped the whole start. Without a URL (an
  emptied setting), the sidecars of the module are removed.
- Modules check their settings in a new optional `mcp_check`. The start
  and `agentbox setup` both run it. If a setting of woodpecker or
  tabularis is not correct, the start now removes what the module runs,
  as for bb4 and for an emptied setting. Before, open sessions kept it.
- A module that is left out for a setting or a secret is removed at once,
  not at the end of the start.
- `agentbox setup` shows "NOT USABLE" and the reason under a module that
  the start would leave out. It also says so when you enable the module.
  If podman cannot list the secrets, setup still opens and shows them as
  MISSING.
- When podman cannot start the sidecar of a module, the warning before the
  session gives the error of podman as the reason (its `Error:` line, or
  else its last line). The output of podman, such as the progress of an
  image pull, shows as it comes.
- When `dbhub.toml` is refused, the warning gives the reason, not "see the
  output above".
- The warnings of the update check are in the list before the session
  too: an image or skill source that could not be updated, and a skill
  record that is not correct. "Could not check" is not in the list,
  because offline it would ask at every start.
- The update check also reminds you when the base of an image that a
  module builds (`agentbox-bb4-devtools`) is a month old.
- A module in `AB_MCP` that this version does not have keeps only the
  sidecars with its mark, not all sidecars with its name prefix.
- A module whose mcp.sh does not parse adds no "unknown key" warnings for
  its settings.
- `agentbox uninstall` also finds the images of a module of yours when
  `MCP_IMAGES` or the image variable is indented, in single quotes, or
  written as `${VAR}`.
- The start looks up the ID of the agentbox image once. The bb4 devtools
  image is built again once, because its fingerprint is now made like the
  fingerprints of the other images.
- New egress group `chatgpt` (`chatgpt.com`), not enabled by default: pi
  with "OpenAI Codex (legacy)". A business ChatGPT account refuses "Sign
  in with ChatGPT" ("operation not permitted"); the legacy provider is the
  way for it, and the README now says so. A group of yours with the same
  name (`egress.local.d/chatgpt.conf`) replaces this one.
- README: rewritten by the ASD-STE100 rules (Simplified Technical
  English). The facts, commands and links are the same.

Action: if permission rules (`.claude/settings*.json`) or other files of
yours name the page tools of bb4, change `mcp__chrome-devtools__` to
`mcp__bb4-devtools__`.

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
