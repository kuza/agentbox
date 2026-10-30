# agentbox

[![Release](https://img.shields.io/github/v/release/kuza/agentbox)](https://github.com/kuza/agentbox/releases/latest)
[![License](https://img.shields.io/github/license/kuza/agentbox)](LICENSE)
[![Linux, rootless Podman](https://img.shields.io/badge/Linux-rootless%20Podman-892CA0?logo=podman&logoColor=white)](#requirements)
[![Checks](https://github.com/kuza/agentbox/actions/workflows/checks.yml/badge.svg)](https://github.com/kuza/agentbox/actions/workflows/checks.yml)
[![Box](https://github.com/kuza/agentbox/actions/workflows/box.yml/badge.svg)](https://github.com/kuza/agentbox/actions/workflows/box.yml)
[![Scan](https://github.com/kuza/agentbox/actions/workflows/scan.yml/badge.svg)](https://github.com/kuza/agentbox/actions/workflows/scan.yml)

Run [Claude Code](https://code.claude.com/docs), or the [pi](https://pi.dev) coding agent with OpenAI models (ChatGPT subscription or API key), in an isolated rootless Podman container that can reach only:

- the model API (Anthropic for Claude Code; OpenAI for pi),
- MCP servers for **Context7** (library documentation) and, each optional, **Grafana** (with **Prometheus** via Grafana), **Graylog**, **GitHub**, **Woodpecker CI** (read-only) and **Tabularis** (your databases through the Tabularis desktop app).

No host credentials are mounted into the agent container, and all service tokens (Grafana, Graylog, GitHub, Woodpecker) live only in sidecar containers that the agent cannot read; database passwords stay with Tabularis on the host. `git push` is done on the host.

## Contents

- **[Getting started](#getting-started):** [Quick start](#quick-start) · [Requirements](#requirements) · [Setup in detail](#setup-in-detail) · [Daily usage](#daily-usage)
- **[How it works](#how-it-works):** [Architecture](#architecture) · [Security model](#security-model) · [Git on the host](#git-on-the-host) · [Egress](#egress)
- **[Agents](#agents):** [pi (OpenAI)](#pi-openai) · [Memory and personal instructions](#memory-and-personal-instructions) · [Status line](#status-line) · [Skills](#skills)
- **[Integrations](#integrations):** [MCP servers](#mcp-servers) · [GitHub (MCP)](#github-mcp) · [Woodpecker (MCP)](#woodpecker-mcp) · [Tabularis (MCP)](#tabularis-mcp) · [DBHub (MCP)](#dbhub-mcp) · [Documentation (Context7)](#documentation-context7)
- **[In the box](#in-the-box):** [Python](#python) · [Go](#go) · [Graphify](#graphify) · [Trivy](#trivy)
- **[Your projects](#your-projects):** [Local services](#local-services) · [Test servers](#test-servers) · [Per-project environment](#per-project-environment)
- **[Maintenance](#maintenance):** [Releases](#releases) · [Updates](#updates) · [Disk space](#disk-space) · [Uninstall](#uninstall) · [Troubleshooting](#troubleshooting) · [Token not picked up](#token-not-picked-up)
- **[Reference](#reference):** [Configuration reference](#configuration-reference) · [Files](#files) · [Tests](#tests) · [Not yet verified](#not-yet-verified)

## Getting started

### Quick start

Needs Linux with rootless Podman 4.x or newer on the netavark backend (`podman info --format '{{.Host.NetworkBackend}}'` prints `netavark`) and a Claude subscription.

**1. Install a release** and check its signature (the key is under [Releases](#releases)):

```bash
# The latest release (https://github.com/kuza/agentbox/releases); or set v=vX.Y.Z
v="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/kuza/agentbox/releases/latest)"; v="${v##*/}"
[[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$v" || echo "could not find the latest release; set v=vX.Y.Z by hand"
mkdir -p ~/Downloads/agentbox && cd ~/Downloads/agentbox
curl -fLO https://github.com/kuza/agentbox/releases/download/$v/agentbox-$v.tar.gz
curl -fLO https://github.com/kuza/agentbox/releases/download/$v/agentbox-$v.tar.gz.sig
printf '%s\n' 'kuza namespaces="agentbox-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUXjyDJluvnJbz14VtB4pBbNA29xyauZarIyDlEPSR2' > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I kuza -n agentbox-release -s agentbox-$v.tar.gz.sig < agentbox-$v.tar.gz
tar -xzf agentbox-$v.tar.gz && agentbox-$v/install.sh   # answer y to git-guard
```

With git-guard, `install.sh` also writes `~/.config/environment.d/agentbox.conf`, which puts it first in `PATH` for your whole desktop session ([Git on the host](#git-on-the-host)). Log out and back in, then check that `command -v git` prints `~/.local/bin/git`.

**2. Sign in to Claude:**

```bash
agentbox login
```

It builds the image (a few minutes the first time), installs Claude Code in the box, and starts `claude setup-token` there: open the URL it prints, sign in, paste the browser's code back, then paste the token it prints (`sk-ant-oat01-...`) at the hidden prompt. The token is stored as the Podman secret `claude_oauth`. Run it again when the token expires; a first `agentbox` without a token offers it too.

**3. Work:**

```bash
cd ~/src/your-repo
agentbox          # Claude Code in the box; agentbox pi for pi, agentbox shell for bash
```

Then `agentbox setup` turns on what you need: MCP servers for Grafana, Graylog, GitHub or Tabularis, skill sources, the hosts the agent may reach, Trivy ([Setup menu](#setup-menu)). In more detail: MCP servers for Grafana, Graylog, GitHub or Tabularis ([MCP servers](#mcp-servers)), skills ([Skills](#skills)), your test databases ([Test servers](#test-servers)). `agentbox update` brings new releases, `agentbox uninstall` removes it all ([Uninstall](#uninstall)).

### Requirements

- Linux with rootless Podman **4.x or newer** and the **netavark** network backend
  ```bash
  podman --version
  podman info --format '{{.Host.NetworkBackend}}'   # must print: netavark
  ```
- For the optional Grafana and Graylog MCP servers: network access from the host to them, and **Graylog 7.0+** for its built-in MCP endpoint (marked experimental by Graylog)
- A Claude subscription or Anthropic account for `claude setup-token`

### Setup in detail

[Quick start](#quick-start) does all of this with `install.sh` and `agentbox login`. This section is the long form: what each step does, the optional parts (service accounts and secrets for the MCP servers), and the manual way.

#### 1. Install and configure

Install a release (below), or, to work on agentbox itself, clone the repository and run `./run.sh` from the clone; [Releases](#releases) says why that clone must not be the copy you open in the box.

```bash
# The latest release (https://github.com/kuza/agentbox/releases); or set v=vX.Y.Z
v="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/kuza/agentbox/releases/latest)"; v="${v##*/}"
[[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$v" || echo "could not find the latest release; set v=vX.Y.Z by hand"
curl -fLO https://github.com/kuza/agentbox/releases/download/$v/agentbox-$v.tar.gz
curl -fLO https://github.com/kuza/agentbox/releases/download/$v/agentbox-$v.tar.gz.sig
# The first time, check the signature against the release key (Releases, Trust):
printf '%s\n' 'kuza namespaces="agentbox-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUXjyDJluvnJbz14VtB4pBbNA29xyauZarIyDlEPSR2' > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I kuza -n agentbox-release -s agentbox-$v.tar.gz.sig < agentbox-$v.tar.gz
tar -xzf agentbox-$v.tar.gz
agentbox-$v/install.sh
```

`install.sh` puts the release into `~/.local/share/agentbox/versions/`, links `~/.local/bin/agentbox` to it, creates `~/.config/agentbox/config.env` from the example, and offers to install [git-guard](#git-on-the-host) (never over a `~/.local/bin/git` of your own). From then on `agentbox update` brings newer releases, verifying their signatures itself.

Set up `config.env`. Choose the MCP servers with `AB_MCP`, e.g. `AB_MCP=grafana graylog`, and set what those modules need, such as `GRAFANA_URL` / `GRAYLOG_URL` (base URLs only, without `/api` or `/api/mcp`; trailing parts are stripped anyway). Context7 is always on; skip the steps below for servers you do not use. See [MCP servers](#mcp-servers).

```bash
$EDITOR ~/.config/agentbox/config.env
cp ~/.local/share/agentbox/current/agents/AGENTS.md.example ~/.config/agentbox/AGENTS.md   # optional: personal instructions for the agents, see Memory and personal instructions
```

`config.env` is parsed, not executed, accepts only known keys, and survives updates of `run.sh`. Environment variables override it, and `AB_CONFIG=/path/to/file` points to a different file, e.g. one per environment. An enabled MCP module whose settings or secrets (step 5) are missing stops the script with an error naming them.

Squid is the agent's only way out. It allows the hosts of the enabled MCP modules and of the egress groups in `AB_EGRESS`, by default the Anthropic hosts Claude Code requires (see Claude Code's [network access requirements](https://code.claude.com/docs/en/network-config#network-access-requirements)), `auth.openai.com` and `api.openai.com` for pi with a ChatGPT subscription, PyPI and the Go module proxy. See [Egress](#egress). Hosts that are deliberately **not** allowed:

| Host | Effect of blocking |
|---|---|
| `mcp-proxy.anthropic.com` | No claude.ai connectors (also disabled via env) |
| `registry.npmjs.org`, `github.com` | No plugin installs inside the session |
| `raw.githubusercontent.com` | `/release-notes` does not load |
| `code.claude.com`, `claude.com` | No built-in documentation lookups |
| `*.frame.claudeusercontent.com` | No artifact reads (also disabled via env) |
| Datadog intake hosts | No telemetry (also disabled via `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) |

#### 2. Create read-only service accounts

Only for the MCP servers you enable.

- **Grafana:** Administration → Users and access → Service accounts → create an account with role **Viewer** → *Add service account token*.
- **Graylog:** create a dedicated user with a read-only role, then System → Users and Teams → *Tokens* → create an API token. Enable MCP in Graylog's settings.

#### 3. Create networks, build the image, install Claude Code

`agentbox login` does steps 3 and 4 and the `claude_oauth` part of step 5 for you, interactively. The manual way:

```bash
podman network create --internal ab-internal
podman network create ab-egress
podman build -t localhost/agentbox -f Containerfile .

podman run --rm --network ab-egress --userns=keep-id:uid=1000,gid=1000 \
  -v ab-claude-tools:/opt/claude --entrypoint npm localhost/agentbox \
  install -g --prefix /opt/claude @anthropic-ai/claude-code@latest
```

`run.sh` does all of this automatically too, but it refuses to start until the secrets from step 5 exist, so do it manually the first time.

#### 4. Get a Claude token

Run this inside the box, so Claude Code is not needed on the host:

```bash
podman run --rm -it --network ab-egress --userns=keep-id:uid=1000,gid=1000 \
  -v ab-claude-tools:/opt/claude:ro localhost/agentbox setup-token
```

Open the printed URL in a browser, sign in, and paste the code shown in the browser **back into this terminal**. `setup-token` then exchanges it and prints the long-lived token.

> **Code vs. token.** The browser shows a short-lived *authorization code*. That is not the token. The token is printed by `setup-token` in the terminal afterwards and always starts with `sk-ant-oat01-`. Only the token goes into the secret. Storing the code results in `401 Invalid bearer token`.
>
> `OAuth error: Request failed with status code 400` during this step means the code was rejected: it expired, was pasted incompletely, or was already used. Run `setup-token` again and paste the fresh code right away.

#### 5. Create Podman secrets

`read -s` keeps tokens out of your shell history.

> **Run these commands one at a time.** Paste one line, press Enter, then paste only the token at the prompt. Pasting the whole block at once makes each `read` consume the next pasted command line as its input, and the secrets end up containing shell commands instead of tokens.

```bash
read -rsp 'Claude token: '  T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create claude_oauth -; echo
# only for the grafana / graylog modules:
read -rsp 'Grafana token: ' T && printf '%s' "$T" | podman secret create grafana_sa -; echo
read -rsp 'Graylog token: ' T && printf '%s:token' "$T" | base64 -w0 | podman secret create graylog_basic -; echo
unset T
podman secret ls
```

The Graylog secret is `base64("<token>:token")`, the literal word `token` is the password, as Graylog expects.

#### 6. MCP servers: nothing to register

`run.sh` gives both agents the servers of the modules in `AB_MCP`, plus Context7, on every start: Claude Code through `--mcp-config`, pi through its `mcp.json`. Caller tokens are generated as Podman secrets and reach the session only as environment variables. See [MCP servers](#mcp-servers).

`claude mcp list` does not show these servers; use `/mcp` inside a session. Servers registered by hand earlier (`claude mcp add` for grafana, graylog, github, context7) are removed on the next start when their name and URL match a module, so they do not show up twice.

There is no separate Prometheus server: `mcp-grafana` includes tools for querying Prometheus datasources configured in Grafana. If that is not enough, add a module.

#### 7. Verify

```bash
agentbox ~/src/myrepo
```

Inside the session:

- `/mcp` shows `context7` and the servers in `AB_MCP` as connected.
- Ask Claude to run `curl -sI https://example.com`. Expected: **403** from squid.
- Ask Claude to run `env | grep -iE 'token|key|pass'`. Expected: `CLAUDE_CODE_OAUTH_TOKEN` and the caller tokens `AB_MCP_TOKEN_*`, which only open the sidecars.
- If enabled: ask for the latest errors from Graylog and the `up` status of Prometheus targets to confirm the MCP servers reach their backends.

### Daily usage

```
agentbox [repo-dir] [claude args...]        Claude Code
agentbox pi [repo-dir] [pi args...]         pi
agentbox shell [repo-dir] [bash args...]    bash in the same box, no agent
agentbox setup                              a menu for config.env (below)
```

If the first argument is an existing directory, it is mounted as the repo. Otherwise the **current directory** is used and all arguments go to the agent. It prints which directory it mounts, and refuses to mount agentbox's own code, the installed versions, git-guard or your files in `~/.config/agentbox`.

```bash
cd ~/src/myrepo && agentbox                      # current directory
agentbox ~/src/myrepo                            # explicit repo
agentbox --dangerously-skip-permissions          # current directory + claude flags
agentbox ~/src/myrepo -p "say ok"                # explicit repo + claude args
```

Relative paths are resolved against **your** current directory. A first argument that happens to be the name of a directory in your current directory is taken as the repo; for a claude subcommand with such a name, pass the repo explicitly: `agentbox . <subcommand>`. The words `pi`, `shell`, `login`, `setup`, `version`, `update`, `rollback` and `uninstall` are agentbox's own commands; open a directory with such a name as `./pi`.

`agentbox` runs `run.sh` from the installed version; this README names `run.sh` where it describes what happens at a start. Settings in the environment go in front, as in `AB_UPGRADE=1 agentbox`.

Tab completes agentbox's commands, the repo directory and the options of `update` and `uninstall` in bash. The installed version links its completion as `~/.local/share/bash-completion/completions/agentbox`, which the `bash-completion` package loads; a file of your own there is left alone.

Several sessions can run in parallel. Each gets its own `ab-claude-<pid>` container, and they share the sidecars.

The repo is mounted at `/work/<repo dir name>`, which is also the working directory. Claude Code keeps per-project state (memory, session history, `/resume`, project permissions) by that path, so each repo gets its own; two repos with the same directory name share it.

#### Copying out of a session

The box has no access to your desktop's clipboard (no X11 or Wayland socket, no `xclip` or `wl-copy`). Text reaches your clipboard only through your terminal: Claude Code sends it as an OSC 52 escape sequence (`/copy` for the last response, or a mouse selection in the session), and the terminal puts it into the clipboard, if it supports and allows that.

- **kitty** works as it is: its default `clipboard_control` lets programs write the clipboard and asks before they read it. Hold **Shift** to select with kitty's own selection instead of Claude Code's.
- **Other terminals:** check that the terminal supports OSC 52 and allows programs to write the clipboard; some need it switched on, some do not support it at all. Claude Code says "Copied to clipboard" either way, so try a paste.
- **tmux or screen** in between must pass OSC 52 on to the terminal (tmux: `set-clipboard`).

#### Setup menu

`agentbox setup` edits `~/.config/agentbox/config.env` (or `AB_CONFIG`) through a menu:

```
MCP servers (AB_MCP; context7 is always on)
  1 [x] github         GitHub pull requests, issues, CI runs and repository contents
        GH_TOOLSETS (default) · secret github_pat: stored · e 1
  2 [x] grafana        Grafana dashboards, alerts and Prometheus/Loki queries (read-only)
        GRAFANA_URL=https://grafana.example.internal · secret grafana_sa: stored · e 2
  3 [x] graylog        Search and analyse logs in Graylog (read-only)
        GRAYLOG_URL=https://graylog.example.internal · secret graylog_basic: MISSING · e 3
...
Hosts the agent may reach (AB_EGRESS)
  6 [x] anthropic      api.anthropic.com platform.claude.com claude.ai
  7 [ ] chatgpt        (yours) chatgpt.com
...
Other settings
 13 [ ]                AB_TRIVY: Trivy in the box (rebuilds the image)
 14                    AB_SERVICES=  (your dev containers the agent may reach, e.g. redis postgres)
number: toggle or edit; e <number>: settings and secrets of a module; s: save; q: quit
```

It lists every MCP module, skill source and egress group there is, shared ones and yours (`mcp.local/`, `skills.local.d/`, `egress.local.d/`, marked "(yours)"), with what is on, and the other settings. Under a module are its settings, with their values ("(default)" when unset, "NEEDED" when it cannot start without one, "(environment)" when your environment sets it), and its Podman secrets: stored, MISSING, or new (typed, not saved yet).

- A number turns an entry on or off, or asks for a value: Enter keeps it, `-` unsets it.
- Turning a module on asks for its settings and, hidden, for the secrets it lacks; the prompt says what to type, and the module turns that into the secret (Graylog's token becomes its basic-auth value). Turning it off again before saving drops what was typed for it.
- `e <number>` asks for all settings and secrets of a module, on or off, without turning it on or off. For a secret that is stored, a new value replaces it and Enter keeps it: the way to put in a renewed token.
- `s` saves: `config.env` is edited in place, keeping your comments and the order of its lines (a link stays a link; the file it points to is edited), the previous file is kept as `config.env.bak`, and the secrets are stored. `q` quits, asking first when something is not saved.

Tokens never go into `config.env`. The menu only edits; the next `agentbox` start applies it: it starts or removes sidecars, changes squid's list, installs skills, rebuilds the image. Open sessions keep what they started with. A setting also set in your environment wins over the file; the menu names such settings.

## How it works

### Architecture

```
                 ab-internal (podman --internal, no route to the outside)
 ┌──────────────┐     │
 │ ab-claude-*  │─────┼──► ab-egress (squid) ───► allowlisted hosts only
 │ repo mounted │     ├──► ab-mcp-grafana ──────► Grafana (+ Prometheus datasources)
 │ no secrets*  │     ├──► ab-mcp-graylog ──────► Graylog /api/mcp
 └──────────────┘     │    (nginx, injects auth)
                      ├──► ab-mcp-github ───► ab-mcp-github-srv ──► api.github.com
                      │    (nginx, caller auth,   (github-mcp-server,
                      │     injects PAT)           ab-egress only)
                      ├──► ab-mcp-woodpecker ──► ab-mcp-woodpecker-srv ──► ab-mcp-woodpecker:8081 ──► Woodpecker
                      │    (nginx, caller auth)   (woodpecker-mcp,           (same nginx: GET/HEAD
                      │                            read-only, own network)    only, injects the token)
                      ├──► ab-mcp-dbhub ──────► your databases (dbhub.toml, read-only tools)
                      └──► ab-mcp-tabularis ──► ab-mcp-tabularis-relay ──► supergateway ──► tabularis --mcp
                           (nginx, caller auth,  (socat, host network,     (host service,
                            unix socket)          unix socket → loopback)   127.0.0.1)
```

| Container | Networks | Holds secrets | Purpose |
|---|---|---|---|
| `ab-claude-<pid>` | `ab-internal` | Claude OAuth token only | Claude Code session, one per run |
| `ab-egress` | `ab-internal`, `ab-egress` | none | Squid forward proxy with a domain allowlist |
| `ab-mcp-grafana` | `ab-internal`, `ab-egress` | Grafana service account token | Official `grafana/mcp-grafana`, streamable HTTP on `:8000/mcp`, bearer-token caller auth, Host allowlist, `--disable-write`, usage stats off. Module `grafana` |
| `ab-mcp-graylog` | `ab-internal`, `ab-egress` | Graylog API token | nginx reverse proxy to Graylog's built-in MCP endpoint: checks the caller token, replaces it with Graylog's `Authorization`. Module `graylog` |
| `ab-mcp-github` | `ab-internal`, `ab-egress` | GitHub PAT | nginx: checks the caller token, injects the PAT, pins toolsets and lockdown mode. Module `github` |
| `ab-llm-openai` | `ab-internal`, `ab-egress` | OpenAI API key | nginx: checks the caller token, injects the API key, forwards to `api.openai.com` with certificate verification. Only for pi in API-key mode |
| `ab-mcp-github-srv` | `ab-egress` **only** | none | Official `github-mcp-server` in HTTP mode. Not reachable from the agent. Module `github` |
| `ab-mcp-woodpecker` | `ab-internal`, `ab-egress`, `ab-mcp-woodpecker` | Woodpecker token, bridge key | nginx: on `:8080` checks the caller token and sends the bridge key on to the server; on `:8081` lets the server read Woodpecker (GET and HEAD only, bridge key checked, token injected, certificate verified). Module `woodpecker` |
| `ab-mcp-woodpecker-srv` | `ab-mcp-woodpecker` **only** (`--internal`, no outside DNS) | none | `rtuszik/woodpecker-mcp` in read-only mode; sees nginx and nothing else, not even squid. Not reachable from the agent. Module `woodpecker` |
| `ab-mcp-dbhub` | `ab-internal`, `ab-egress` | Database passwords (from your `dbhub.toml`, via a mode-600 copy in the cache) | `bytebase/dbhub`: bearer-token caller auth, Host allowlist, read-only tools only. Module `dbhub` |
| `ab-mcp-tabularis` | `ab-internal` **only** | Tabularis bridge key | nginx: checks the caller token, replaces it with the bridge key, forwards to the relay's unix socket. Module `tabularis` |
| `ab-mcp-tabularis-relay` | host network | none | socat: the unix socket in the volume `ab-mcp-tabularis-sock`, forwarded to supergateway on `127.0.0.1`. Not reachable from the agent. Module `tabularis` |

The `tabularis` module also runs a program on the host, outside any container: the systemd user service `agentbox-mcp-tabularis` (see [Tabularis (MCP)](#tabularis-mcp)).

Volumes:

| Volume | Mounted in agent as | Contents |
|---|---|---|
| `ab-claude-home` | `/home/node` (rw), Claude Code sessions only | Claude Code settings, session history, MCP registrations |
| `ab-pi-home` | `/home/node` (rw), pi sessions only | pi settings, sessions, ChatGPT sign-in (`~/.pi/agent/auth.json`) |
| `ab-cache` | `/home/node/.cache` (rw), both agents | uv cache, Go build cache, per-repo Python virtualenvs |
| `ab-go` | `/home/node/go` (rw), both agents | Go module cache, `go install` binaries |
| `ab-pi-tools` | `/opt/pi` (**ro**) | pi installation |
| `ab-claude-tools` | `/opt/claude` (**ro**) | Claude Code installation |

Each agent has its own home volume, so neither can read the other's credentials or change the other's configuration (for example plant a hook in `~/.claude/settings.json` from a pi session). The two cache volumes are shared because they hold no configuration or credentials, only downloaded packages and build output.

\* The agent container holds `CLAUDE_CODE_OAUTH_TOKEN`. The agent can technically read it, but it only grants Claude access and can only be sent to the hosts in the egress allowlist.

### Security model

**What is isolated**

- **Network.** The agent sits on a `--internal` network. Its only way out is the squid proxy, which allows the Context7 documentation server (`mcp.context7.com`), which the setup relies on, and the [egress groups](#egress) you enable: by default the three Anthropic hosts Claude Code needs (`api.anthropic.com`, `platform.claude.com`, `claude.ai`), pi's OpenAI sign-in, and package sources for Python and Go. Everything else, GitHub included, gets a 403. External host names do not even resolve in the session (`--dns 127.0.0.1`), so DNS queries cannot carry data out either; container names do.
- **claude.ai connectors.** `ENABLE_CLAUDEAI_MCP_SERVERS=false` stops Claude Code from loading MCP connectors configured in your claude.ai account (mail, chat, drives, ...). Only the MCP servers registered inside the box are available.
- **Credentials.** Nothing from the host environment, `~/.ssh`, `~/.aws`, `~/.kube` etc. is visible. Grafana, Graylog and GitHub tokens exist only in their sidecars, provided as Podman secrets.
- **The agent's own binary.** Claude Code is installed into `ab-claude-tools` by a separate short-lived container and mounted read-only, so the agent cannot modify its own executable.
- **Host-side git execution.** `.git/hooks`, `.git/config` and `.git/modules` are mounted read-only, `.git` itself is a mount of its own (it cannot be renamed and replaced), and the `.git` file of a worktree or submodule is read-only. A writable copy would let the agent plant a hook or `core.fsmonitor` that runs **on the host** the next time you run `git commit` or `git status`. The rest of `.git` stays writable for commits, branches and worktrees; [git-guard](#git-on-the-host) on the host covers what that leaves open.
- **Process hardening.** `--cap-drop=ALL`, `no-new-privileges`, rootless Podman.

**What is NOT isolated**

- **The rest of `.git` is writable, and git on the host trusts it.** The agent can write `.git/commondir`, or point a worktree's `.git` file at a directory it made, so that git on the host uses that directory's config and hooks; the next `git status`, including the one your editor runs by itself, then runs its command outside the box. **Install [git-guard](#git-on-the-host)**, which refuses such a repository before git runs. Without it this path is open.
- The repository is mounted read-write. The agent can change any file in it. Review diffs before running anything from the repo on the host (`Makefile`, scripts, `.envrc`, CI config, editor tasks).
- MCP tools act with the permissions of their service accounts. **Isolation does not limit what the tokens can do**, so make them read-only (see step 2). The same goes for Tabularis: the agent runs SQL with your saved connections, limited only by Tabularis's own read-only mode and approvals.
- Squid filters by hostname and does not inspect TLS. A broad allowlist entry (e.g. a whole git hosting service) is a potential exfiltration path.
- The kernel is shared with the host, as in any container. The session has no capabilities and a seccomp filter, but it can still create new user namespaces (`unshare -Ur`), which some kernel privilege-escalation exploits rely on; podman cannot switch that off per container without a custom seccomp profile. Keep the host kernel updated. `tests/escape.sh` reports it as a WARN.
- "No credentials in the box" stops the agent from using **your** accounts, not someone else's. Every allowlisted API that accepts writes with a bearer token (`api.anthropic.com`, `api.openai.com`, and `storage.googleapis.com` or `github.com` if you enable them) could be used with a token planted through prompt injection to upload data to an attacker's account. Keep the allowlist to what you actually use.

### Git on the host

The agent commits, branches and creates worktrees in the box, so most of the repository's `.git` is writable there. Git on the host trusts what it finds in `.git`: a `.git/commondir` file, or a worktree's `.git` file, pointing at a directory the agent made, makes it use that directory's config and hooks, and `core.fsmonitor` in there runs a command on the next `git status`. Editors run `git status` by themselves whenever files change.

`git-guard` closes this. It is a wrapper installed as `git` ahead of the real one. `run.sh` records every directory it mounts in `~/.config/agentbox/mounted-repos`, with the git dir git may use there, worked out from the paths before the session starts: the repository's own `.git`, the main `.git` of a mounted worktree or subdirectory, or none for a directory that was no repository. Inside a recorded directory git-guard checks, before git runs, that

- git would use exactly that git dir for config and hooks (read-only in the box), or a submodule's directory under its `modules/` (read-only as well); where none was recorded, any repository is the agent's and is refused;
- that git dir has no `commondir` file;
- a worktree's git dir is `<git dir>/worktrees/<name>`;
- with `extensions.worktreeConfig` on (sparse-checkout turns it on), the `config.worktree` files, which the agent can write, hold only sparse-checkout settings;
- `git rebase --continue` finds no `exec` lines in a rebase the agent left half done.

Otherwise git stops with an explanation. Other repositories go straight to git. The check costs one `git rev-parse`, which reads the config but executes nothing from it. `tests/run.sh` reproduces the attacks with real git and checks that plain git falls for them and git-guard does not.

`install.sh` installs it when you answer `y` (or with `--git-guard`), as a **copy**: it runs on every git call, so it must not be a link into a clone a session can write. It never replaces a `~/.local/bin/git` of your own. By hand, from a clone:

```bash
mkdir -p ~/.local/bin
install -m 755 git-guard ~/.local/bin/git
```

`~/.local/bin` must come first in `PATH`, for your shells and for programs started from the desktop (editors). On systemd desktops (Fedora, Ubuntu, ...) that is `~/.config/environment.d/agentbox.conf`, effective at the next login. agentbox writes it when it installs git-guard, and an installed agentbox writes it at its next start if git-guard is there and the file is not. It does so once per installation: delete the file to do without, and it does not come back. A file or link that is there is never changed, and `agentbox uninstall` removes the file only if it is still as agentbox wrote it. Its content:

```
# agentbox: git-guard (~/.local/bin/git) ahead of the system git, for every
# program of the login session (README, Git on the host). Remove this file
# to do without; agentbox does not write it again.
PATH=$HOME/.local/bin:$PATH
# No repository config can switch on core.fsmonitor, even for a program that
# calls /usr/bin/git directly. Replaces GIT_CONFIG_* entries of your own set
# in an earlier environment.d file.
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=core.fsmonitor
GIT_CONFIG_VALUE_0=false
```

If you set `GIT_CONFIG_COUNT` entries of your own for the session, merge them into one file: the `environment.d` file read last sets the count, and the other's entries are lost.

Check with `command -v git` (should print `~/.local/bin/git`) in a terminal and in your editor's terminal. Editors with a setting for the git executable (VS Code `git.path`, JetBrains "Path to Git executable") can point at `~/.local/bin/git` explicitly. `run.sh` warns at every start while `git` is not git-guard.

An installed agentbox updates the copy at every `agentbox update` and `rollback`. Running from a clone, update it yourself (`install -m 755 git-guard ~/.local/bin/git` from the copy you run).

What it does not cover, because the agent writes the files that git on the host then uses:

- **Hooks that run files from the work tree.** If your repository's config points `core.hooksPath` into the work tree (husky: `.husky/_`), or a hook runs tools configured there (the pre-commit framework reads `.pre-commit-config.yaml`), the agent can change what runs on your next `git commit` on the host. Review the diff of such files before committing there, or commit from the box.
- **A rebase the agent left half done.** git-guard looks for `exec` lines only on `git rebase --continue`; `--skip` or an abbreviation (`--cont`) runs them unchecked. Look at `.git/rebase-merge/git-rebase-todo`, or `git rebase --abort`, before going on with a rebase you did not start.
- **Directories that are not repositories of yours.** Mounting `~/.local`, `~/.cache` or similar would let the agent change git-guard itself or files agentbox generates; `run.sh` refuses only the code, `~/.config/agentbox` and their parents. Mount repositories.
- A program that calls `/usr/bin/git` directly runs unchecked; the `environment.d` setting above still keeps `core.fsmonitor` off for it.
- Submodules cannot be updated inside the box, since `.git/modules` is read-only there.

### Egress

The hosts the agent may reach, apart from the MCP modules' remote servers, come in groups:

| Where | What |
|---|---|
| `egress.d/<name>.conf` | Shared groups, in git |
| `egress.local.d/<name>.conf` | Your own, in [your files](#your-files). A name that also exists in `egress.d/` replaces that group |

`AB_EGRESS` in `config.env` lists the enabled ones. Unset, it is `anthropic openai pypi go`; a list replaces that default entirely, and `AB_EGRESS=` (empty) enables none. Claude Code does not start without `anthropic`; pi needs `openai` only with a ChatGPT subscription (with an API key it goes through its sidecar), so someone using only pi with a key can leave out both. On every start `run.sh` writes the hosts of the enabled groups and of the enabled MCP modules into a file `squid.conf` includes, and recreates squid when it changed. Open sessions lose egress for a moment.

| Group | Hosts | For |
|---|---|---|
| `anthropic` | `api.anthropic.com`, `platform.claude.com`, `claude.ai` | Claude Code, required by it |
| `pypi` | `pypi.org`, `files.pythonhosted.org` | pip / uv packages (see [Python](#python)) |
| `go` | `proxy.golang.org`, `sum.golang.org` | Go modules (see [Go](#go)) |
| `openai` | `auth.openai.com`, `api.openai.com` | pi with a ChatGPT subscription (see [pi](#pi-openai)) |
| `github-read` | `github.com` and its content hosts | anonymous read access to public GitHub (see [GitHub read access](#github-read-access-optional)) |
| `gcs` | `storage.googleapis.com` | Google Cloud Storage, all buckets |

A group file is data, never run: one host per line, `#` starts a comment.

```
# egress.local.d/test-data.conf
test-data.s3.eu-central-1.amazonaws.com   # HTTPS (port 443) and plain HTTP (port 80) to this host
.test.example                             # test.example and all its subdomains
minio.test.example:9000                   # this host on this port only, HTTPS or plain HTTP
```

```
AB_EGRESS=anthropic openai pypi go test-data
```

- Prefer exact hosts to domains. `.amazonaws.com` is all of AWS, and any API that accepts uploads with a token is an exfiltration path (see [Security model](#security-model)): the agent can use a token planted through prompt injection. An S3 bucket host is narrower than the regional endpoint.
- Credentials for these services go in a [per-project environment](#per-project-environment) file. The agent sees them; use test credentials with the least rights, read-only where possible.
- Squid sees only host names, so an allowed host is allowed for any path and any method, on port 443 (HTTPS) and 80 (plain HTTP); other ports only as `host:port` entries.
- The list is the same for all sessions: squid is shared.
- Only HTTP(S) goes through squid. Databases and queues are [local services](#local-services) or [test servers](#test-servers).

## Agents

### pi (OpenAI)

[pi](https://pi.dev) runs in the same box as Claude Code: same image, networks, squid, MCP sidecars, repo protections, Python and Go. Start it with `agentbox pi` instead of `agentbox`; arguments work the same way.

> Do not use the Claude subscription token with pi. Anthropic permits subscription OAuth only in Claude Code and Claude.ai, not in third-party tools.

There are two ways to give pi OpenAI models. Both use pi's **OpenAI** provider (`openai/...` models); `run.sh` picks the mode by whether the `openai_api_key` secret exists.

| | ChatGPT subscription (default) | OpenAI API key |
|---|---|---|
| Sign-in | `/login` → OpenAI → *Sign in with ChatGPT*, once | `openai_api_key` Podman secret |
| Billing | Your ChatGPT plan | Per token, OpenAI platform |
| Credential in the agent container | **Yes**: `~/.pi/agent/auth.json` in `ab-pi-home`, incl. refresh token. Claude Code sessions cannot see it | **No**: only in the `ab-llm-openai` sidecar |
| Egress | `auth.openai.com`, `api.openai.com` via squid | none, through the sidecar |
| `pi/models.json` | one without overrides (`{ "providers": {} }`) | points the provider at the sidecar |

**Do not use "OpenAI Codex (legacy)".** It is pi's older ChatGPT integration: it talks to ChatGPT's internal Codex backend (`chatgpt.com/backend-api`), which is not a public API and can change without notice, and pi marks it legacy. *Sign in with ChatGPT* on the OpenAI provider gets a token issued for the public API (`api.openai.com`) and uses the same endpoint and request format as API-key access. Check `/model` for the models your plan offers there.

#### Setup: ChatGPT subscription

1. Start pi in a repo: `cd ~/src/myrepo && agentbox pi`. The first run installs pi into the `ab-pi-tools` volume.
2. Run `/login`, choose **OpenAI**, then **Sign in with ChatGPT**. Open the shown URL in your browser on the host and approve.
3. The browser is then redirected to `http://127.0.0.1:1455/auth/callback?...` and shows a connection error: the callback listener runs inside the container, not on your host. That is expected. **Copy the full URL from the address bar** and paste it into pi's prompt.
4. pi stores the tokens in `~/.pi/agent/auth.json` in `ab-pi-home` and refreshes them itself; this is needed once per box, not per repo.
5. Pick an `openai/...` model with `/model` and press `Ctrl+S` to make it the default.
6. Check MCP with `/mcp`: it lists `context7` and the modules in `AB_MCP`.

**The token is readable by the agent**, as the Claude OAuth token is for Claude Code: pi has to write and refresh it, so it cannot be hidden in a sidecar. To revoke it, run `/logout` in pi and end the session in your ChatGPT account's security settings.

`auth.openai.com` and `api.openai.com` come from the `openai` [egress group](#egress), enabled by default. Squid is shared, so Claude Code sessions can reach them too; leave `openai` out of `AB_EGRESS` if you use pi with an API key or not at all. The legacy provider also needs `chatgpt.com`: add it in a group of your own in `egress.local.d/`.

#### Setup: OpenAI API key

`pi/models.json` points pi's built-in `openai` provider at the `ab-llm-openai` sidecar, which swaps a caller token for the real key and forwards to `api.openai.com` with certificate verification. The key never enters the agent container.

1. Create a project API key with a spending limit in the OpenAI platform.
2. Store it (one command at a time):
   ```bash
   read -rsp 'OpenAI API key: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create openai_api_key -; echo; unset T
   ```
3. `agentbox pi`: creates `llm_openai_caller`, starts the sidecar. Pick an `openai/...` model with `/model`. No `/login`.

#### What pi gets from the host, read-only

| Host file | In the container | Purpose |
|---|---|---|
| `pi/models.json` | `~/.pi/agent/models.json` | OpenAI API endpoint = the sidecar (API-key mode); with a subscription, a `models.json` without overrides (`{ "providers": {} }`) |
| generated by `run.sh` | `~/.pi/agent/mcp.json` | MCP servers of the enabled modules, with caller tokens from env |
| `skills/` | `~/.pi/agent/skills` | Same personal skills as Claude Code |
| `AGENTS.md` | `~/.pi/agent/AGENTS.md` | Same personal instructions as Claude Code, an empty file without one; see [Memory and personal instructions](#memory-and-personal-instructions) |
| `pi-extensions/` in [your files](#your-files) | `~/.pi/agent/extensions` | Extensions you allow (empty by default) |

Read-only matters here: pi executes extensions it finds in its agent directory and reads its model endpoint and MCP servers from these files. If the agent could write them, it could redirect its own model traffic, add servers or plant code that persists across sessions. Sessions, `settings.json` and `auth.json` stay writable in `ab-pi-home`.

pi runs with `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1` and `PI_TELEMETRY=0`: no model catalog refresh, version check or telemetry.

#### Extensions and skills

pi's MCP support is built in, no extension needed. `pi install ...` does not work inside the box (no npm access) and would write to the agent directory anyway. To allow an extension, read it, then copy it into `~/.config/agentbox/pi-extensions/` on the host. Skills come from `skills/`, the same directory Claude Code uses, so `sync-skills.sh` covers both agents. Skills written for Claude Code may rely on Claude-specific features such as subagents and work less well in pi.

### Memory and personal instructions

Claude Code's auto memory is **off by default** in the box: `run.sh` sets `autoMemoryEnabled: false` in `~/.claude/settings.json` when that key is not set yet, so an explicit choice there is kept. To use it in one project, set `"autoMemoryEnabled": true` in that repo's `.claude/settings.json`.

Instructions that should apply in every repo go in `~/.config/agentbox/AGENTS.md`. Start from the template, which has the rules this box relies on (ask before committing, where to look up library documentation):

```bash
cp agents/AGENTS.md.example ~/.config/agentbox/AGENTS.md
```

Both agents get the same file, **read-only**: Claude Code as `~/.claude/CLAUDE.md`, pi as `~/.pi/agent/AGENTS.md` (its global context file). Read-only for the same reason as personal skills (see [Skills](#skills)): written by the agent in its home volume, it would carry over into every future session. Without `AGENTS.md` they get an empty file there: these paths are always mounted, because a file mounted only sometimes leaves an empty, root-owned placeholder in the volume that a session without the mount would read and fail on. So a `CLAUDE.md` that Claude Code's `/memory` or `#` notes wrote into its volume is not seen; agentbox warns at each start while such a file is there, with the commands to read and remove it. Keep the text agent-neutral; name an agent only where a rule is specific to it. Changes apply at the next session start, also when you edit the file from inside a session: the running session keeps the version it started with.

### Status line

`claude/statusline.py` draws Claude Code's status line: model, repo directory and git branch, context window use, the 5-hour and weekly subscription limits with their reset times, and the session cost. Percentages turn yellow from 50% and red from 80%. A part whose data Claude Code does not send (limits with an API key, context before the first reply) is left out.

A copy of the script, made at each start in `~/.cache/agentbox/session/claude/` (an installed version's own files cannot be relabelled for SELinux), is mounted read-only as `~/.claude/statusline.py`; edit `claude/statusline.py` in a clone, not the copy. `run.sh` adds the `statusLine` setting to `~/.claude/settings.json` only when that key is absent, so your own status line there is kept and replaces this one; to switch to this one, delete the key and start a new session. Times use the host's time zone: `run.sh` passes it to the session as `TZ`.

**About `--dangerously-skip-permissions`.** Inside this box it is a reasonable choice: the worst case is modified files in the repo (recoverable via git), read access to Grafana and Graylog within Viewer rights, and requests to allowlisted hosts. It is only reasonable if the service accounts are really read-only.

### Skills

Claude Code picks up skills from two places, and both work in the box without network access:

| Kind | Location | How it gets into the box |
|---|---|---|
| Project skills | `<repo>/.claude/skills/<name>/SKILL.md` | Nothing to do: the repo is mounted |
| Personal skills | `~/.claude/skills/<name>/SKILL.md` | Put them in `~/.config/agentbox/skills/`; it is mounted **read-only** over `~/.claude/skills` |

```
agentbox/
├── run.sh
└── skills/
    ├── go-review/
    │   └── SKILL.md
    └── incident-triage/
        ├── SKILL.md
        └── scripts/collect.sh
```

To keep skills elsewhere, set `AB_SKILLS_DIR=/path/to/skills`. Changes are picked up at the next session start, no restart of sidecars needed. Check with `/skills` in a session.

**Why read-only.** `~/.claude` lives in the writable `ab-claude-home` volume. Skills written there by the agent itself would silently persist into every future session and every repo, which makes them a convenient place for a prompt injection to survive. With the read-only mount only you change personal skills, from the host. Project skills are part of the repo and go through your normal diff review.

Scripts bundled with a skill run inside the box, with the same network and credential restrictions as everything else.

**Plugins and marketplaces** (`/plugin install ...`) and `npx skills add` do not work in the box: they download from `github.com` and `registry.npmjs.org`, which are blocked. Use a skill source (below), which `run.sh` installs on the host.

#### Skill sources: `AB_SKILLS`

A skill source is a git repository of skills, described in a small file:

| Directory | |
|---|---|
| `skills.d/<name>.conf` | Shared sources, in git: `mattpocock` |
| `skills.local.d/<name>.conf` | Your own, in [your files](#your-files). A name that also exists in `skills.d/` replaces that source |

`AB_SKILLS` in `config.env` lists the enabled ones (`AB_SKILLS=mattpocock`). Nobody gets skills they did not enable. The `.conf` is `KEY=VALUE` data, never run: Each repository can be one source only: two sources with the same `URL` stop the start with an error; list the skills of both in one `ONLY`.

| Key | |
|---|---|
| `URL` | Required. Git URL of the repository |
| `ONLY` | Comma-separated skills to install, as named in the repository. Default: all |
| `PREFIX` | Prefix for the installed names. Default: the repository owner; `PREFIX=` (empty) for none |
| `REF` | Branch, tag or commit to pin to. Default: the default branch, with updates offered by the [update check](#update-check) |

On every start `run.sh` compares each enabled source with what is installed and syncs on the host only when they differ: it installs a new source, re-syncs one whose `.conf` changed (at the installed commit, so a changed `ONLY` does not also upgrade it), and removes the skills of a source taken out of `AB_SKILLS`. Without a change there is no network access. A failed sync prints a warning and the session starts with what is installed.

Read what you enable: skills are instructions the agent follows, and bundled scripts run in the box. Before accepting an update, read the compare link the update check prints. A team's own skills go into a repository of their own and a source in `skills.d/`, like anyone else's.

##### How a source is installed: `sync-skills.sh`

`run.sh` calls `sync-skills.sh`, which also works by hand for a one-off repository. It clones the repository afresh into a scratch directory (no clone is kept: it would live where a session that mounts agentbox can write, and a hook planted in it would run on the host), finds every directory with a `SKILL.md` at any depth and copies it **flat** into `skills/<name>/`, because Claude Code only looks one level deep. It records what it installed, from where and at which commit in `skills/.sources/<owner>__<repo>`, removes skills dropped upstream or deselected, and never overwrites a skill it did not install. A skill that contains symlinks is not installed: the link could point at a file on your host, which would then end up in the agent's skills.

Installed skills get a prefix, the repo owner by default: `code-review` from `mattpocock/skills` becomes `mattpocock-code-review`. Without it, a vendored skill shadows a Claude Code built-in with the same name (`/code-review`), and two repos can collide. The script renames the directory and the frontmatter `name`, and adds a note after the frontmatter of each `SKILL.md`: the text still says `/tdd` or `call the Skill tool with "code-review"`, and the note tells the agent to use `mattpocock-<name>` for the listed skills. The text itself is not rewritten.

```bash
./sync-skills.sh <git-url> [ref]               # ref: branch, tag or commit; default: remote default branch
SKILLS_ONLY=a,b,c ./sync-skills.sh <git-url>    # install a subset; upstream names, without the prefix
SKILLS_PREFIX=mp ./sync-skills.sh <git-url>     # another prefix; SKILLS_PREFIX= (empty) installs names unchanged
./sync-skills.sh --remove <git-url>             # remove what it installed from there
```

Skills synced by hand are not managed by `run.sh`: it neither changes nor removes them. Older versions kept clones and records in `vendor/`; `run.sh` moves the records to `skills/.sources/` on its next start, and the clones (`vendor/<owner>__<repo>/`) are no longer used and can be deleted.

##### Example: mattpocock/skills

`skills.d/mattpocock.conf` installs engineering and productivity skills from the repository, without the unfinished `in-progress` ones. Enable it with `AB_SKILLS=mattpocock`.

Then in a session, once per repo: `/mattpocock-setup-matt-pocock-skills`. Things to know for this box:

- **Issue tracker.** The GitHub option tells the agent to use the `gh` CLI, which the box does not have. Either pick **local markdown** during setup, or pick GitHub and afterwards edit the generated issue-tracker document in your repo to say "use the github MCP tools" instead of `gh` commands (requires [GitHub (MCP)](#github-mcp)). The other skills read that document, so the change applies everywhere.
- **`mattpocock-pr`** creates pull requests. It needs GitHub MCP, and the branch must already be pushed from the host.

## Integrations

### MCP servers

Each MCP server is a module: a directory with an `mcp.sh` and whatever else it needs (an nginx template, say).

| Directory | |
|---|---|
| `mcp/<name>/` | Shared modules, in git: `context7`, `grafana`, `graylog`, `github`, `woodpecker`, `tabularis`, `dbhub` |
| `mcp.local/<name>/` | Your own modules, in [your files](#your-files). A name that also exists in `mcp/` replaces that module |

`AB_MCP` in `config.env` lists the enabled ones (`AB_MCP=grafana graylog`); `context7` is always on. On every start `run.sh` checks the enabled modules' settings and secrets, starts their sidecars, and writes one MCP config for both agents (Claude Code: `--mcp-config`, pi: `~/.pi/agent/mcp.json`) plus the remote hosts for squid (see [Egress](#egress)). Nobody gets servers they did not enable, and adding one does not touch `run.sh`.

#### Writing a module

`mcp.sh` is bash that `run.sh` sources on the host. It sets variables and, if the server needs a sidecar, defines `mcp_start`:

| | |
|---|---|
| `MCP_URL` | Required. The URL the agents connect to: `http://ab-mcp-<name>:<port>/mcp` for a sidecar, the server's URL for a remote one |
| `MCP_DESCRIPTION` | One line, shown by pi |
| `MCP_CONFIG=(...)` | `config.env` keys the module reads; `run.sh` accepts them only while the module is enabled |
| `MCP_REQUIRED_CONFIG=(...)` | Of those, the ones that must be set |
| `MCP_SECRETS=(...)` | Podman secrets that must exist, e.g. the service's API token |
| `MCP_SECRET_HELP=(...)` | Optional: `"<secret>: what to type"` for each secret, shown when `agentbox setup` asks for it |
| `mcp_secret_value()` | Optional: `<secret> <what was typed>` → the value to store, for a secret that is not stored as typed (`graylog` stores `base64("<token>:token")`) |
| `MCP_OWN_SECRETS=(...)` | Podman secrets `mcp_start` creates itself; `agentbox uninstall --all` removes them |
| `MCP_CALLER_SECRET` | Name of a caller token secret, generated on first use. The agents send `Authorization: Bearer <token>`, the sidecar checks it; in the session it is `AB_MCP_TOKEN_<NAME>` |
| `MCP_EGRESS=(...)` | Hosts the agent itself connects to (remote servers); they are added to squid's allowlist |
| `MCP_IMAGES=(...)` | Images `AB_UPGRADE` pulls |
| `mcp_start()` | Starts the sidecars with `start_sidecar <container> <podman run arguments>`. Name them `ab-mcp-<something>`: `run.sh` removes containers with that prefix that no enabled module started. `$MCP_DIR` is the module's directory, `$IMG_NGINX` the nginx image the shipped modules use. Mount the module's files as `-v "$(sidecar_copy <container> "$MCP_DIR/<file>"):<path>:ro,Z"`, never directly (see [Troubleshooting](#troubleshooting), files that cannot be read). A program that has to run on the host goes through `start_host_unit agentbox-mcp-<something> [VAR=value...] -- <command...>`: a transient systemd user service, restarted when its command changes and stopped once no enabled module asks for it (see `mcp/tabularis/`) |

A remote server needs three lines, like `mcp/context7/mcp.sh`:

```bash
MCP_DESCRIPTION="Issue tracker"
MCP_URL="https://mcp.example.com/mcp"
MCP_EGRESS=(mcp.example.com)
```

A server that needs a credential gets a sidecar that holds it, so the token never enters the agent container: see `mcp/graylog/` (nginx adds the header) and `mcp/grafana/` (the server checks a caller token). Attach sidecars to `ab-internal` (the agent reaches them by name) and `ab-egress` (their way out).

**A module is code that runs on your host** with your user, like `run.sh` itself. Read a module before you enable it, and treat a `mcp.local/` module from someone else like a script from them.

### GitHub (MCP)

Optional: the `github` module (`AB_MCP=... github`). With it, `run.sh` starts two extra sidecars and the agent gets GitHub through MCP: pull requests, issues, review comments, CI runs and logs, reading repository contents. **The token never enters the agent container**, and `github.com` stays out of the egress allowlist.

What the agent can **not** do: `git fetch`/`git push`, or change code on GitHub. Code goes through you:

1. the agent commits locally in the mounted repo;
2. you review the diff and `git push` from the host;
3. the agent opens the PR, reads CI results and review comments through MCP.

#### How it is wired

- **`ab-mcp-github-srv`** runs the official `github-mcp-server` in HTTP mode. It holds no token and is attached to `ab-egress` only, so the agent cannot reach it directly.
- **`ab-mcp-github`** (nginx, `mcp/github/nginx.conf.template`) is the only entry point. It
  - rejects requests without the caller token (`github_mcp_caller`, generated automatically);
  - replaces the caller token with the PAT;
  - pins `X-MCP-Toolsets` to `GH_TOOLSETS` and `X-MCP-Lockdown: true`, and drops any `X-MCP-Readonly`, `X-MCP-Tools` or `X-MCP-Insiders` sent by the client;
  - always proxies to the server root, so the agent cannot switch to other server paths.

The agent can add MCP registrations of its own in `ab-claude-home`, so server behaviour is enforced in nginx, not in the client config. **The real boundary is still the PAT's permissions.**

Default toolsets: `context,repos,issues,pull_requests,actions`. Override with `GH_TOOLSETS` in `config.env`; the next start recreates the sidecar.

Lockdown mode hides content in public repositories from users without push access to them. It currently covers reading issues only, so content fetched from public repositories by other tools can still carry prompt injection.

#### 1. Create a fine-grained personal access token

GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.

- **Resource owner:** your organization (may need org approval).
- **Repository access:** *Only select repositories*, just the ones the agent works on.
- **Expiration:** short, e.g. 30 to 90 days.
- **Repository permissions:**

| Permission | Access | Why |
|---|---|---|
| Metadata | Read | Required by GitHub |
| Contents | **Read** | Read files, branches, commits. No writes: code changes go through your `git push` |
| Pull requests | Read and write | Open PRs, read and post review comments |
| Issues | Read and write | Read and comment on issues (drop if not needed) |
| Actions | Read | CI runs and logs |
| Workflows | **No access** | |

Leave everything else at *No access*. With Contents set to Read, the agent cannot create branches, commit files or modify workflows on GitHub, whatever tools the server exposes.

Also protect `main` with a branch ruleset that requires a pull request, so merges always need your approval.

#### 2. Store the token and enable the module

```bash
read -rsp 'GitHub token: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create github_pat -; echo; unset T
```

Add `github` to `AB_MCP` in `config.env`. The next start creates `github_mcp_caller` and the sidecars; check with `/mcp` in a session.

#### Disable

Remove `github` from `AB_MCP`, then:

```bash
podman rm -f ab-mcp-github ab-mcp-github-srv
podman secret rm github_pat github_mcp_caller
```

#### GitHub read access (optional)

The GitHub MCP sidecar covers your own repositories. For **anonymous read access to public GitHub** (cloning a library to read its source, `uv` dependencies from git, raw files, release downloads), add `github-read` to `AB_EGRESS`; the next start recreates squid.

What it does and does not change:

- **No writes.** There is no GitHub token in the agent container, so it cannot push, open issues, comment or create gists. Your private repositories stay unreachable this way, too.
- **It cannot be limited to reads at the network level.** Squid sees only the host name of a `CONNECT`, not the HTTP method or path, so it allows any request to these hosts. Without credentials that is harmless for GitHub itself, but each allowed host is still a place the agent can send requests to.
- **Main risk is inbound.** Public repositories, issues and READMEs are arbitrary third-party text and code: a prompt injection source and a supply-chain source, like PyPI. Weigh this against what the agent can read in the box: your code, and whatever the MCP servers return, such as logs.

Leaving it off and asking the agent to read public repositories through the GitHub MCP tools (the PAT can read public repositories) is the more contained alternative.

### Woodpecker (MCP)

Optional: the `woodpecker` module (`AB_MCP=... woodpecker`). The agent reads [Woodpecker CI](https://woodpecker-ci.org/): repositories, pipelines and their status, step logs, pipeline configs, the queue. **Read only**: it cannot start, restart, cancel or approve anything.

Woodpecker has no official MCP server. The module runs [`rtuszik/woodpecker-mcp`](https://github.com/rtuszik/woodpecker-mcp), pinned to one release in `mcp/woodpecker/mcp.sh` and scanned daily with the other images.

#### How it is wired

Woodpecker's personal access tokens have no scopes: a token can do all its user can, including starting pipelines that get the CI's secrets. So the token never reaches the MCP server, and writing is refused below it:

- **`ab-mcp-woodpecker-srv`** runs woodpecker-mcp with its write tools removed (`WOODPECKER_MCP_READ_ONLY`), only on the `--internal` network `ab-mcp-woodpecker` and without DNS for outside names: it sees nginx and nothing else, not even squid on `ab-internal`, and the agent cannot reach it. Its "Woodpecker" is nginx's port 8081, and the token it forwards there is a bridge key, not Woodpecker's.
- **`ab-mcp-woodpecker`** (nginx, `mcp/woodpecker/nginx.conf.template`):
  - on `:8080`, for the agent: checks the caller token (`woodpecker_mcp_caller`) and sends the bridge key (`woodpecker_bridge_key`, generated) on to the server;
  - on `:8081`, for the server: checks the bridge key, lets **GET and HEAD only** through, puts in the Woodpecker token and verifies Woodpecker's certificate. Whatever the server's code does, nothing but reading reaches Woodpecker.

#### Setup

1. In Woodpecker, log in as a user for the agent that can only read the repositories it needs: Woodpecker takes permissions from your forge (Gitea, GitHub, GitLab, ...), so read access there is enough. Your own user works too, with all your rights behind the token, but the GET-only proxy still keeps it to reading.
2. Under your user's settings, copy the personal access token.
3. `agentbox setup`: turn `woodpecker` on, enter `WOODPECKER_URL` (e.g. `https://ci.example.internal`) and the token, which is stored as the Podman secret `woodpecker_token`. By hand: `WOODPECKER_URL=...` in `config.env`, `woodpecker` in `AB_MCP`, and `read -rsp 'Woodpecker token: ' T && printf '%s' "$T" | podman secret create woodpecker_token -; echo; unset T`.
4. For an https Woodpecker signed by your own CA, set `WOODPECKER_CA` to the CA certificate file on the host.

#### Things to watch

- **Step logs are third-party text.** Woodpecker masks the values of its secrets in logs, but anything else a step prints reaches the agent, and can carry prompt injection like any other content.
- `/mcp` shows the server failing with 401 from Woodpecker: the token is wrong or expired; `e <number>` in `agentbox setup` replaces it.

#### Disable

Remove `woodpecker` from `AB_MCP`. The next start removes the sidecars. The secrets stay until you remove them (or `agentbox uninstall --all` does): `podman secret rm woodpecker_token woodpecker_bridge_key woodpecker_mcp_caller`.

### Tabularis (MCP)

Optional: the `tabularis` module (`AB_MCP=... tabularis`). [Tabularis](https://tabularis.dev) is a desktop database client with a built-in MCP server. With the module, the agent sees the connections you saved in Tabularis and can list tables, read schemas and run SQL through them. **Database passwords stay on the host**, in Tabularis and your system keychain; the agent container gets neither them nor a route to the databases.

#### How it is wired

Tabularis's MCP server (`tabularis --mcp`) speaks only stdio and needs what the app has on the host: the saved connections, the keychain, and the open app window where writes are approved. So it runs on the host, and a chain of three parts connects it to the box:

- **`agentbox-mcp-tabularis`**, a transient systemd user service that agentbox starts and restarts by itself (`systemd-run --user`; no unit file, gone when you log out). It runs [supergateway](https://github.com/supercorp-ai/supergateway), installed from `mcp/tabularis/bridge/package-lock.json` (below), which
  - listens on `127.0.0.1:TABULARIS_PORT` only, never on the network;
  - requires the bridge key (`tabularis_bridge_key`, generated; its file is `~/.cache/agentbox/tabularis/bridge.key`, mode 600), so other users on the host cannot use it while it runs;
  - starts one `tabularis --mcp` per MCP session (`--stateful`): Tabularis handles one request at a time, so a write waiting for approval in one session does not block the others.
- **`ab-mcp-tabularis-relay`**, socat on the host network: it holds a unix socket in the volume `ab-mcp-tabularis-sock` and forwards it to `127.0.0.1:TABULARIS_PORT`. A container holds the socket because SELinux does not let containers connect to a socket a host process holds. It has no secrets and the agent cannot reach it.
- **`ab-mcp-tabularis`** (nginx, `mcp/tabularis/nginx.conf.template`), on `ab-internal` only: it rejects requests without the caller token (`tabularis_mcp_caller`), replaces that token with the bridge key and forwards to the socket.

Tabularis writes every query and its result to stderr. The module sends that to `/dev/null` and runs supergateway with `--logLevel none`, so no data from your databases ends up in the journal.

#### Setup

1. Install Tabularis on the host and save your connections in it. The command `tabularis` must be in `PATH`, or set `TABULARIS_CMD` in `config.env`, e.g. `TABULARIS_CMD=flatpak run <app id>` (`--mcp` is appended).
2. Install Node.js (`node` and `npm`) on the host. The first start installs supergateway with it, which needs the npm registry once. `ss` (iproute2) must be there too, as it is on Fedora; agentbox uses it to check that the program on `TABULARIS_PORT` is its bridge.
3. In Tabularis, under Settings → MCP, decide what the agent may do:
   - **Read-only mode**, per connection (off by default), for every connection the agent needs only to read: Tabularis refuses anything but `SELECT` there.
   - **Approval mode**: by default every write waits until you approve it in the Tabularis window (120 s, then it is refused), and with Tabularis not running (quit, not just its window closed) writes are refused at once. Approving every query, reads included, is the stricter setting; turning approvals off leaves only read-only mode between the agent and your data.
4. Add `tabularis` to `AB_MCP`. The next start creates the secrets, starts the service and the two sidecars, and waits for supergateway to listen; check with `/mcp` in a session.

Keep Tabularis running while you work if the agent should write: approvals need the app.

#### Things to watch

- **This is your access to your databases.** Isolation does not limit what Tabularis does with a query it accepts. Read-only mode and approvals in Tabularis are the boundary, so set them before you enable the module, and leave out connections the agent has no business with.
- **Query results are third-party text.** Data from a database can carry prompt injection like any other content.
- **A program of agentbox runs on your host.** supergateway comes from npm and runs with your user, like `run.sh`. Not just its own version but every package under it is pinned, with its hash, in `mcp/tabularis/bridge/package-lock.json`: the module installs exactly that tree with `npm ci --ignore-scripts` into `~/.cache/agentbox/tabularis/bridge-<hash of package.json and the lock file>`. npm refuses a package whose content differs from the hash, and no package's install scripts run. A new agentbox release with a changed lock file installs the new tree at the next start; trees no start has used for 30 days are removed. If `npm ci` fails (no registry, say), the start stops and says so: remove `tabularis` from `AB_MCP` to start without it. `package.json` also overrides the MCP SDK packages supergateway pins (`@modelcontextprotocol/sdk`, `server`, `client`) with later releases that fix vulnerabilities, two of them in serving several sessions at once, which is how the bridge runs. Maintainers update the lock file with `cd mcp/tabularis/bridge && npm install --package-lock-only --ignore-scripts`, after bumping a version in `package.json`, check it with `trivy fs mcp/tabularis/bridge`, and review the diff; an override goes once supergateway pins a fixed release itself.
- **On a host shared with other users** the bridge's port is an ordinary TCP port on `127.0.0.1`. agentbox checks at every start that the bridge holds it, but while the bridge is down (stopped, failed, or after you log out) another local user could take the port and receive the agent's requests, bridge key included. supergateway cannot listen on a unix socket, which would close this. On a machine only you use, this does not apply.
- `TABULARIS_PORT` (default `47821`) must be free on the host: if another program listens there, agentbox stops with an error rather than send the agent's requests and the bridge key to it. If `/mcp` shows the server as failed, see `systemctl --user status agentbox-mcp-tabularis`. A bridge that fails three times within a minute (supergateway refusing to start, say) stays down until the next agentbox start. supergateway logs nothing on purpose; to see an error, run it by hand with the command shown there, without `--logLevel none`.

#### Disable

Remove `tabularis` from `AB_MCP`. The next start stops the service and removes the sidecars. The secrets, the socket volume and the key file stay until you remove them (or `agentbox uninstall` does):

```bash
podman secret rm tabularis_mcp_caller tabularis_bridge_key
podman volume rm ab-mcp-tabularis-sock
rm -r ~/.cache/agentbox/tabularis
```

### DBHub (MCP)

Optional: the `dbhub` module (`AB_MCP=... dbhub`). The agent reads SQL databases you list: it searches schemas, tables, columns and indexes and runs queries, **read only**. [DBHub](https://github.com/bytebase/dbhub) speaks PostgreSQL, MySQL, MariaDB, SQL Server, Oracle and SQLite; with two tools in all it costs the agent little context. Unlike [Tabularis](#tabularis-mcp) it needs nothing on the host, but there is no window to approve writes: it only reads.

#### How it is wired

- **`ab-mcp-dbhub`** runs `bytebase/dbhub`, pinned to one release in `mcp/dbhub/mcp.sh` and scanned daily with the other images, on `ab-internal` and `ab-egress`: it connects to the databases directly, since a database connection is not HTTP and cannot go through squid. It rejects requests without the caller token (`dbhub_mcp_caller`); a `Host` allowlist on top guards against DNS rebinding.
- **Your `dbhub.toml`** lists the databases as `[[sources]]`, with their passwords. DBHub does not read it. At every start `mcp/dbhub/config.py` parses it with Python's TOML parser (in a throwaway container of the agentbox image, without network) and writes DBHub's config anew from what it parsed: your sources, their values only strings, numbers, booleans and lists of those, and for each source the two tools the agent gets, `execute_sql` with `readonly = true` and `search_objects`. Anything else in `dbhub.toml` stops the start: another table (`[[tools]]` among them, since a tool of yours could write), a source without an `id`, a nested table or a date. Since DBHub gets only what agentbox wrote, nothing in your file can be read one way by agentbox and another by DBHub. The result goes to `~/.cache/agentbox/sidecars/ab-mcp-dbhub/dbhub.toml` (mode 600), a copy with the passwords, and is mounted into the sidecar; a changed source recreates it at the next start. If `dbhub.toml` is deleted or refused, the start removes the sidecar of the last start and that copy, so deleting the file takes the access away. The session never sees the passwords.
- **Read-only** in DBHub is two checks: it refuses statements that are not reads, and on PostgreSQL, MySQL, MariaDB and Oracle it runs each query in a `READ ONLY` transaction, so the database itself refuses a write the first check missed. The real boundary is the database user, below.

#### Setup

1. For each database, create a user that can only read what the agent needs (PostgreSQL: `CREATE ROLE agent LOGIN PASSWORD '...'`, then `GRANT CONNECT`, `GRANT USAGE ON SCHEMA` and `GRANT SELECT ON ALL TABLES IN SCHEMA`, or `pg_read_all_data` for everything).
2. Write `~/.config/agentbox/dbhub.toml`, one `[[sources]]` per database. `id` (letters, digits, `_`, `-`; DBHub reads `-` as `_`, so `prod-db` and `prod_db` would clash) is the name the agent picks a database by; `description` tells it what is there:

   ```toml
   [[sources]]
   id = "billing"
   description = "Billing: invoices, payments, customers"
   dsn = "postgres://agent:PASSWORD@db1.example.internal:5432/billing?sslmode=require"
   lazy = true

   [[sources]]
   id = "crm"
   dsn = "postgres://agent:PASSWORD@db2.example.internal:5432/crm?sslmode=require"
   lazy = true
   query_timeout = 30
   ```

   `lazy = true` connects at the first query to that database. Without it DBHub connects to all of them at its start and exits if one fails, and the agent gets none.

   `chmod 600 ~/.config/agentbox/dbhub.toml`: it holds passwords, and agentbox warns while the group or others may read it. Special characters in a password are URL-encoded in a DSN (`@` as `%40`); or use `type`, `host`, `port`, `database`, `user` and `password` instead of `dsn`. Other source settings (`query_timeout`, `connection_timeout`, `sslmode`, ...) are in [DBHub's TOML reference](https://dbhub.ai/config/toml).
3. `agentbox setup`: turn `dbhub` on (or add it to `AB_MCP`). The next start starts the sidecar; check with `/mcp` in a session.

#### Things to watch

- **TLS.** Set `sslmode` in each DSN: `require` encrypts but does not check the server's certificate, `disable` sends the password and the data in clear. `verify-ca` and `verify-full` against your own CA need a CA file in the container, which the module does not mount yet; nor does it support SSH tunnels (`ssh_*`). The sidecar reaches what the host's network reaches.
- **Names in your network.** The sidecar resolves database hosts through Podman's DNS, which uses the host's resolvers; if a name does not resolve, see the Troubleshooting row "Sidecar can't resolve Grafana/Graylog".
- **Query results are third-party text.** Data from a database can carry prompt injection like any other content.
- `/mcp` shows `ENOTFOUND ab-mcp-dbhub`: the sidecar exited, usually because a database refused it at start (see `lazy` above). `podman logs ab-mcp-dbhub` names the database and the reason, such as `no pg_hba.conf entry for host ...`: PostgreSQL's `pg_hba.conf` has no rule for that user from your host's address, with or without SSL as the DSN asks.

#### Disable

Remove `dbhub` from `AB_MCP`. The next start removes the sidecar and the copy with the passwords in the cache (if you removed the container by hand before, the copy stays: `rm -r ~/.cache/agentbox/sidecars/ab-mcp-dbhub`). `dbhub.toml` stays, and so does the caller token until you remove it (or `agentbox uninstall --all` does): `podman secret rm dbhub_mcp_caller`.

### Documentation (Context7)

The model's knowledge stops at its training date, and `WebFetch` cannot open documentation sites because squid blocks them. [Context7](https://github.com/upstash/context7) (by Upstash) fills the gap: an MCP server with two tools, `resolve-library-id` (library name → Context7 ID) and `query-docs` (current documentation and code examples for that library, optionally for a specific version). The agent talks only to `mcp.context7.com`, never to arbitrary pages. The `agents/AGENTS.md.example` template tells both agents to look there first.

#### Setup

None: Context7 is the `context7` module, always enabled. Its host `mcp.context7.com` reaches squid's allowlist through the module, and both agents get the server. Check with `/mcp` in a session.

No API key is used: the anonymous tier has lower rate limits but needs no secret. If the limits get in the way, put the key in an nginx sidecar the way Graylog's token is handled, so it never enters the agent container.

#### Things to watch

- **Queries leave the box.** Library names and questions go to Upstash. Write them as you would a search query, without code or data from the repo.
- **Documentation is third-party text.** Anyone can add a library to Context7, so its content is a prompt injection source, like PyPI or public GitHub.
- **A planted key is a write path.** Context7 accepts bearer keys. As with the other allowlisted APIs (see [Security model](#security-model)), a key planted through prompt injection would send queries to someone else's account.

## In the box

### Python

The image has [uv](https://docs.astral.sh/uv/) and preinstalled interpreters, so Python projects work in the box without any setup.

| | |
|---|---|
| Interpreters | `AB_PYTHON_VERSIONS` in `config.env` (default `3.12 3.13 3.14`, from the `Containerfile`), installed at build time into `/opt/uv-python`, on `PATH` as `python3.12`, `python3.13`, `python3.14`. The system `python3` is Debian 13's 3.13; graphify's own virtualenv uses it |
| Packages | `uv add`, `uv sync`, `uv run`, `pip` inside a venv: PyPI is in the egress allowlist |
| Virtualenv | Per repo, **outside the repo**, in `ab-cache` (`~/.cache/venvs/<repo>-<hash>`), via `UV_PROJECT_ENVIRONMENT`. Shared by both agents |
| uv cache | `ab-cache`, persists across sessions, shared by both agents |

Interpreters cannot be downloaded at runtime (`UV_PYTHON_DOWNLOADS=never`; their source, GitHub, is blocked anyway). For another version, list it in `AB_PYTHON_VERSIONS` (all the versions you want, e.g. `3.11 3.12 3.13 3.14`); the next start rebuilds the image.

**Why the venv is outside the repo.** A `.venv` created in the container points at `/opt/uv-python/...`, which does not exist on the host, and a host `.venv` points at host paths. Sharing one directory breaks whichever side used it last. With `UV_PROJECT_ENVIRONMENT`, `uv` in the box never touches `<repo>/.venv`, so you can keep using your host venv in parallel. Projects that do not use uv (plain `python -m venv .venv`) are not covered by this; create such venvs outside the repo too, e.g. under `~/.venvs`.

**PyPI is a trade-off.** It lets the agent install packages on its own, which is convenient, but it is also how a malicious or typo-squatted package would get into the box. The damage stays inside the box (no host credentials, no other egress), but the code it writes ends up in your repo. Review `pyproject.toml` / `uv.lock` changes in your diffs. To make dependency changes go through you, leave `pypi` out of `AB_EGRESS` (see [Egress](#egress)); then run `uv sync` once from a container with internet access, or add packages on the host.

### Go

The image has the Go toolchain and [golangci-lint](https://golangci-lint.run), both from the official release archives and verified against their published SHA-256 checksums.

| | |
|---|---|
| Versions | `AB_GO_VERSION`, `AB_GOLANGCI_LINT_VERSION` in `config.env` (defaults from the `Containerfile`). Go defaults to `1.26`: a minor version means the latest stable patch release of it at build time, an exact version (`1.26.3`) pins it, empty means the latest stable Go. golangci-lint empty (default) = latest release at build time. `AB_UPGRADE` brings whatever these resolve to; the build log prints what was installed |
| Modules | `proxy.golang.org` and `sum.golang.org` are in the egress allowlist, so `go mod download`, `go get`, `go build` work |
| Caches | Module cache in `ab-go` (`~/go`), build cache in `ab-cache`, both persist and are shared by both agents |
| Tools | `go install pkg@version` lands in `~/go/bin`, which is on `PATH` |
| Toolchain switching | Off: `GOTOOLCHAIN=local`. A `go.mod` that needs a newer Go fails with a clear error instead of downloading a toolchain; rebuild with `AB_UPGRADE=1` |
| cgo | On: `gcc` and `libc6-dev` are in the image, so `go test -race` and packages with C code build |
| make | Installed, so a project's `Makefile` targets run, except those that need podman/docker or hosts outside the allowlist |

Things to know:

- **Private modules** (`GOPRIVATE`, your organisation's repositories) are fetched directly from the git host with credentials, which the box does not have. Use `go mod vendor` on the host and build with `-mod=vendor` in the box.
- **golangci-lint and the Go version.** golangci-lint must be built with a Go version at least as new as the one your `go.mod` targets. With both versions left on "latest" they stay in step; if you pin one, pin the other to match.
- **Same trade-off as PyPI.** The module proxy lets the agent add dependencies on its own. `sum.golang.org` guarantees you get the same code as everyone else for a given version, not that the code is benign. Review `go.mod` / `go.sum` changes; to keep dependency changes on the host, leave `go` out of `AB_EGRESS`.
- `govulncheck` needs `vuln.go.dev`, which is not allowlisted.

### Graphify

[graphify](https://github.com/Graphify-Labs/graphify) turns the repo into a queryable knowledge graph. It is a Python CLI plus a `/graphify` skill that calls it, so unlike plain skills it has to be **in the image**: the agent cannot install it from PyPI.

The `Containerfile` installs it into `/opt/graphify` and exposes it as `/usr/local/bin/graphify`. The version is pinned with `GRAPHIFY_VERSION`; optional extras with `AB_GRAPHIFY_EXTRAS` in `config.env` (none by default), e.g. `[terraform]` for Terraform/HCL (`.tf`, `.tfvars`, `.hcl`) or `[sql,terraform]`. A change to either rebuilds the image at the next start.

#### The skill

`run.sh` installs the `/graphify` skill from the image, so it always matches the CLI there: it runs `graphify install` into a scratch home and copies the result (`SKILL.md` plus its `references/`) to `skills/graphify/` for Claude Code, and pi's own variant to `~/.cache/agentbox/graphify-pi/graphify/`, mounted over the shared one in pi sessions. It records the image ID next to the skill and refreshes both whenever the image changes, e.g. after a rebuild with a new `GRAPHIFY_VERSION`. A `skills/graphify/` that `run.sh` did not install is left alone, with a warning.

The `~/.claude/CLAUDE.md` pointer that `graphify install` writes on a normal host is not used: Claude Code finds the skill in `~/.claude/skills` on its own.

#### Enable it in a repo

The skill needs nothing per repo: `/graphify .` builds the graph into `graphify-out/`. Add `graphify-out/` to `.gitignore`.

Optionally, inside a session:

```bash
graphify claude install         # graphify section in CLAUDE.md, plus a Claude Code PreToolUse hook in .claude/settings.json that nudges the agent to query the graph before grep/read
```

These are Claude Code hooks, not git hooks; graphify's git hooks (`graphify hook install`) cannot be installed in the box, see below.

A repo set up earlier with `graphify install --project` has its own copy in `.claude/skills/graphify/` and a pointer block in `.claude/CLAUDE.md`, and `/graphify` then exists twice. Delete the directory and the `# graphify` block in `.claude/CLAUDE.md` by hand. Not with `graphify uninstall`: it also removes the `graphify claude install` setup, the `AGENTS.md` sections and git hooks.

#### What works in the box

- **Code graph:** fully local (tree-sitter), no network. Verified offline with `graphify extract . --code-only`.
- **Docs, PDFs, images:** inside the `/graphify` skill the semantic pass uses the Claude session itself, so it works on your subscription. Headless `graphify extract` on docs needs an API key and does not work in the box; use `--code-only` there.
- **Queries:** `graphify query`, `path`, `explain` on `graph.json`.

What does **not** work, by design: `/graphify add <url>`, `graphify clone` and video/URL transcription (no internet), `graphify prs` (no `gh`), and `graphify hook install` (`.git/hooks` is read-only, so graphify git hooks can never run code on the host). Ask the agent to run `graphify update .` after larger changes instead.

#### Things to watch

- **The hooks contain an absolute path.** `graphify claude install` writes `/usr/local/bin/graphify hook-guard ...` into `.claude/settings.json`. If you also open this repo with Claude Code on the host, those hooks run **on the host** and need graphify at that same path there; otherwise they fail.
- **`.claude/settings.json` and `CLAUDE.md` are shared if committed.** Hooks in a committed `settings.json` run for every colleague who opens the repo with Claude Code. Decide deliberately whether to commit them, or keep them out of git with `.git/info/exclude` on the host.
- graphify creates `.claude/settings.json.graphify-bak` when it edits settings; don't commit it.
- The query log is turned off in the image (`GRAPHIFY_QUERY_LOG_DISABLE=1`).

### Trivy

[Trivy](https://trivy.dev) scans the repository in the box: `trivy fs .` for known vulnerabilities in dependencies (lock files, `go.mod`, ...), `trivy config .` for misconfigurations in Terraform, Dockerfiles, Kubernetes manifests and the like. Off by default; enable it in `config.env` and rebuild:

```
AB_TRIVY=1
```

```bash
AB_UPGRADE=1 agentbox
```

- **The database stays outside the session.** Trivy downloads its vulnerability database as an image from `mirror.gcr.io` or `ghcr.io`; the session cannot reach those, since a registry also takes uploads. Like the agent update, `run.sh` fetches it in a short-lived container, at most every 6 hours (`AB_UPDATE=1` forces it), into the `ab-trivy` volume, which the session mounts read-only.
- **No downloads in the session**: `TRIVY_SKIP_DB_UPDATE`, `TRIVY_SKIP_JAVA_DB_UPDATE`, `TRIVY_SKIP_CHECK_UPDATE`, `TRIVY_SKIP_VERSION_CHECK`, `TRIVY_SKIP_VEX_REPO_UPDATE` and `TRIVY_DISABLE_TELEMETRY` are set (the database update runs with telemetry off too), and the scan cache stays in memory (`TRIVY_CACHE_BACKEND=memory`). Misconfiguration checks are the ones built into the Trivy binary; the Java database is not used, so Java artifacts are not checked for vulnerabilities.
- **Version** pinned with `TRIVY_VERSION` in the `Containerfile`, installed from the release archive after a checksum check.
- CI scans agentbox's own images with Trivy every day (`.github/workflows/scan.yml`): a report of fixable HIGH and CRITICAL issues in the run summary, for deciding when to rebuild. It never fails the build.

## Your projects

### Local services

To let the agent use your dev containers (Redis, RabbitMQ, PostgreSQL, ...), list them in `config.env`:

```
AB_SERVICES=redis rabbitmq postgres
```

On start, `run.sh` attaches each one to `ab-services`, a separate `--internal` network that the session joins, and the agent connects by container name and the container's own port: `redis:6379`, `rabbitmq:5672` (management UI `rabbitmq:15672`), `postgres:5432`. Ports published on the host (`-p`) are not used and not needed. The service names are in the session's `NO_PROXY`, so HTTP clients reach them directly, not through squid.

- Only **rootless Podman** containers of the same user can be attached. Docker or rootful containers are invisible to rootless Podman networks; for those, run a copy under rootless Podman.
- The container must be on a **bridge network**. Rootless containers started without `--network` use `pasta` and cannot join another network later (`"pasta" is not supported: invalid network mode`). Recreate them once with `--network podman` (the default bridge network; `-p` and volumes work as before), and `run.sh` attaches them to `ab-services` on the next start:

  ```bash
  podman inspect --format '{{.HostConfig.NetworkMode}}' redis   # pasta -> needs recreating
  podman stop redis && podman rm redis      # data survives only if it is in a volume
  podman run -d --name redis --network podman -p 6379:6379 -v redis-data:/data docker.io/library/redis:7
  ```
- The attachment is persistent, also across container restarts. Undo with `podman network disconnect ab-services <name>`.
- A stopped service is started (`podman start`) and keeps running after the session ends. `run.sh` does not wait for it to become ready: a database that is still initialising refuses connections for a few seconds.
- The services cannot reach the MCP/LLM sidecars, and the session gets no route to the host or the internet through them. A service that itself has internet access (e.g. a RabbitMQ shovel) could still be told to send data out; keep these to plain dev instances.
- **The agent gets full access to that data** with whatever credentials you give it. Use dev data and dev passwords. Put connection settings in a [per-project environment](#per-project-environment) file.
- Clients: the image has Python and Go, so `uv run --with redis`/`psycopg`/`pika` works. `psql` and `redis-cli` are not installed.

### Test servers

To let the agent use databases, queues and other TCP services outside the box, such as those on test servers, give each a name and a target:

```
# config.env: for every session
AB_FORWARD=db=db.test.example:5432

# env/<repo dir name>.conf: only for sessions in that repo
AB_FORWARD=mq=mq.test.example:5672 cache=redis.test.example:6379
```

The agent connects by name and the target's port: `db:5432`, `mq:5672`. For each target `run.sh` starts a sidecar running `socat` on the agentbox image. It sits on `ab-egress`, the way out, and on an `--internal` network the session joins, where it answers to the name:

| List | Network | Sidecars |
|---|---|---|
| `config.env` | `ab-forward` | `ab-fwd-<name>` |
| `env/<repo dir name>.conf` | `ab-fwd-<key>`, joined only by sessions in that repo | `ab-fwd-<key>-<name>` |

`<key>` comes from the repo's path, so another repo's sessions cannot reach these targets. The repo file uses the same `KEY=VALUE` format as `config.env`, accepts only `AB_FORWARD`, and lives with the [per-project environment](#per-project-environment) files, outside the repo: the agent cannot add targets for its next session.

- **Needs socat in the image.** An image built before socat was added gets rebuilt at the next start; if a start with forwards still says socat is missing, `AB_UPGRADE=1 agentbox`.
- **Plain TCP.** The target sees connections from your host, through your network and VPN, like any other client there. TLS (`sslmode=require`, `amqps`) goes end to end; certificates name the real host, so clients that verify host names need it set explicitly (e.g. `sslrootcert` with `sslmode=verify-ca` instead of `verify-full`).
- **Names** are lowercase letters, digits and hyphens, not starting with `ab-`, and unique across both lists and `AB_SERVICES`. The session's `NO_PROXY` includes them, so HTTP clients connect directly.
- **Changes** apply at the next start: changed targets get new sidecars, removed ones are removed. A repo's sidecars change only with a start in that repo. Sidecars keep running between sessions; `socat` opens a connection to the target only when the agent opens one.
- **HTTP(S) services** with a public or internal host name are simpler as an [egress group](#egress): the certificate then matches.
- **The agent gets full access to that data** with whatever credentials you give it. Use test accounts with the least rights; put them in the [per-project environment](#per-project-environment) file.

### Per-project environment

Environment variables for one project, seen only by sessions in the box, go in `~/.config/agentbox/env/<repo dir name>.env`:

```
# env/myapp.env
DB_CONN=host=postgres port=5432 user=dev dbname=myapp_test sslmode=disable password=dev
AMQP_URI=amqp://dev:dev@rabbitmq:5672/%2f
```

`run.sh` passes the file for the mounted directory to the session with `--env-file` and prints its path on start; without a file nothing is passed. Changes apply at the next session start.

- Different projects can use the same variable names with different values, and the agent on the host never sees them.
- Podman format: `KEY=VALUE` per line, `#` comments, the value is taken literally (quotes become part of it). A line with only `KEY` copies that variable from the host environment.
- The file is keyed by the directory name: two repos with the same name share one file.
- The directory is on the host and not mounted, so the agent cannot change what its next session starts with, and the passwords never reach the project's git.
- The variables `run.sh` sets itself (proxy, agent settings) take precedence and cannot be overridden from the file.
- `AB_ENV_DIR` points to a different directory.

## Maintenance

### Releases

Versions are git tags `vX.Y.Z` with a section in `CHANGELOG.md`. A release on GitHub carries `agentbox-vX.Y.Z.tar.gz` (made by `git archive`, so exactly what git tracks, with the version written into `VERSION`) and `agentbox-vX.Y.Z.tar.gz.sig`, an SSH signature (`ssh-keygen -Y sign`, namespace `agentbox-release`).

| Command | What it does |
|---|---|
| `agentbox version` | The version you run; `dev` in a clone |
| `agentbox update` | Finds the latest release, downloads it, verifies the signature against `release/allowed_signers` of the version you run now, shows its CHANGELOG section and installs it next to the old one after you confirm (`--yes`: without asking) |
| `agentbox rollback` | Back to the version before the last switch |
| `agentbox uninstall` | Removes agentbox from the host; see [Uninstall](#uninstall) |

`check-updates.sh` mentions a newer release, at most every 6 hours; it never installs one. Installed versions are read-only; `agentbox uninstall` removes them with the rest.

**Trust.** An update is accepted only if a key in the running version's `release/allowed_signers` signed it, so a new signing key becomes trusted only through a release signed by a trusted one; a compromised GitHub account alone cannot ship an update. The first install has nothing to compare with: check the signature yourself (Install) against this key:

```
kuza namespaces="agentbox-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUXjyDJluvnJbz14VtB4pBbNA29xyauZarIyDlEPSR2
```

Fingerprint `SHA256:KESk+phlkaooJLO6Kk6vP2qWGmGrYrFmU66JIcJ3YBY` (ED25519); check it with `ssh-keygen -lf` on a file holding the key part of that line. The same line is in `release/allowed_signers`.

**Development.** Work in a clone and open that clone in the box like any repository. Run what you use day to day from an installed release, or from a second clone: `run.sh` refuses to mount the copy it runs from, since a session could change code that runs on the host.

**Publishing** (maintainers): add a `## vX.Y.Z` section to `CHANGELOG.md`, commit, push, then on the host

```bash
./release.sh vX.Y.Z
```

It checks the version, the clean and pushed `main`, the CHANGELOG section, that your signing key (`AB_RELEASE_KEY`, else `git config user.signingkey`, else `~/.ssh/agentbox-release`) is in `release/allowed_signers`, and the tests; then makes a signed tag, the archive and its signature in `dist/`, verifies the signature the way `agentbox update` will, and, after you confirm, pushes the tag and creates the GitHub release with `gh`. A new signing key goes into `release/allowed_signers` in a release signed by a key listed there already.

### Updates

| What | Updates how | Command |
|---|---|---|
| Claude Code, pi | **Automatically**, at most every 6 hours, in a separate short-lived container, each into its own volume | `AB_UPDATE=1 agentbox` / `AB_UPDATE=1 agentbox pi` to force |
| Sidecar images (`mcp-grafana`, `github-mcp-server`, nginx) | **Checked at most every 6 hours**, updated after you confirm (see below). podman never re-pulls an image on its own | Answer `y` at the prompt, or `AB_UPGRADE=1 agentbox` |
| Base image (Debian packages, git, Python) and the squid image (Debian's squid, `Containerfile.squid`) | Built here, so only on request: a cached build never re-runs `apt-get`. The update check reminds you once the base image they were last built on was pulled a month ago | `AB_UPGRADE=1 agentbox` |
| graphify | Pinned in `Containerfile` | Bump `GRAPHIFY_VERSION`; the next start rebuilds |
| Trivy | Binary pinned (`TRIVY_VERSION` in `Containerfile`); its database **automatically**, at most every 6 hours, outside the session | Bump `TRIVY_VERSION`; the next start rebuilds. `AB_UPDATE=1 agentbox` fetches the database now |
| Go, golangci-lint | Go: latest 1.26.x at build time; golangci-lint: latest. Both set in `Containerfile` | `AB_UPGRADE=1 agentbox` |
| uv, Python interpreters | Pinned in `Containerfile` | Bump `UV_VERSION` in `Containerfile` / set `AB_PYTHON_VERSIONS`; the next start rebuilds. Which patch release of each version gets installed is decided by the uv version, so bump `UV_VERSION` to get newer patch releases |
| Skills from sources (`AB_SKILLS`) | **Checked at most every 6 hours**, updated after you confirm (see below); pinned sources (`REF`) are skipped | Answer `y` at the prompt, or change `REF` |
| Tokens (Claude, Grafana, Graylog, GitHub, Woodpecker) | Expire on their own schedule | `agentbox login` for Claude Code; for a module, `e <number>` in `agentbox setup` (or recreate the Podman secret). The next start recreates the sidecars that hold it |

`AB_UPGRADE=1` does everything in one go: pulls the sidecar images, rebuilds the base image from scratch (`--pull --no-cache`), updates Claude Code and recreates the sidecars. It does not touch volumes, secrets or MCP registrations. Running it every week or two is a reasonable rhythm; it takes a few minutes because of the full rebuild.

You do not need it after changing a build setting (`AB_TRIVY`, `AB_PYTHON_VERSIONS`, `AB_GO_VERSION`, `AB_GOLANGCI_LINT_VERSION`, `AB_GRAPHIFY_EXTRAS`) or after an agentbox update that changed a `Containerfile`: each image carries a fingerprint of its `Containerfile` and build settings (label `agentbox.build`), and a start whose fingerprint differs rebuilds that image, as a cached build, not from scratch.

#### Update check

`run.sh` runs `check-updates.sh` before it starts the sidecars, at most every `AB_UPDATE_EVERY` seconds (6 hours by default, the same interval as the agent update). Only a check that ends with nothing to update resets the interval: if you decline an update, an update fails or a registry is unreachable, the next session checks again. Running `./check-updates.sh` by hand always checks.

- **Sidecar images.** For each agentbox sidecar container it asks the registry for the digest of the image tag (an anonymous `HEAD` request, which pulls nothing and does not count against Docker Hub's pull limit) and compares it with the local image. It also reports sidecars still running an older image than the local one. Answering `y` pulls the new images and removes the affected sidecars, and `run.sh` recreates them right away. Other open sessions lose those MCP servers until they are restarted.
- **Vendored skills.** `sync-skills.sh` records each sync in `skills/.sources/<owner>__<repo>` (URL, installed commit, `SKILLS_ONLY`, prefix, source, pin, installed names). The check compares that commit with the remote default branch (`git ls-remote`), prints a GitHub compare link to read before updating, and on `y` repeats the sync with the same settings.

Without a terminal (`run.sh -p ...` from a script) it only prints what is out of date. A failed check (no network, registry down) prints a warning and does not stop the session. `AB_CHECK_UPDATES=0` skips it; `AB_UPGRADE=1` skips it too, since that updates the images anyway. Run `./check-updates.sh` on its own to check without starting a session.

The skills directory is writable from inside a session that has the agentbox directory mounted, so the check reads the records as data, accepts only `https://` URLs, and runs git outside any repository: a hook or config planted in the box does not run on the host. `sync-skills.sh` clones afresh into a scratch directory for the same reason.

#### Claude Code

`run.sh` updates it at most once every 6 hours: a container with internet access but without the repo or the agent runs `npm install -g @anthropic-ai/claude-code@latest` into `ab-claude-tools`.

```bash
AB_UPDATE=1 agentbox                # force an update now
AB_UPDATE_EVERY=86400 agentbox      # change the interval (seconds)
```

To pin a version, change `@latest` in `run.sh` to `@x.y.z` and run with `AB_UPDATE=1`.

#### graphify

Check the latest release and what changed before bumping:

```bash
curl -s https://pypi.org/pypi/graphifyy/json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])'
```

Set `GRAPHIFY_VERSION` in `Containerfile`; the next start rebuilds the image. The same run reinstalls the `/graphify` skill from the new image (see [The skill](#the-skill)).

#### Pinning sidecar images

The sidecars use floating tags (`:latest`, `:alpine`), so an upgrade can change their behaviour, as happened with mcp-grafana's caller-auth and Host checks. To control that, pin tags in the `IMG_*` variables at the top of `run.sh` and bump them deliberately. Squid is not pulled: `Containerfile.squid` builds it here from Debian (`localhost/agentbox-squid`), so its packages are as current as the last `AB_UPGRADE=1`.

### Disk space

`run.sh` cleans up after itself:

- **Replaced images.** An upgrade (`AB_UPGRADE=1`, or `y` in the update check) leaves the previous agentbox image and sidecar images as `<none>`. The next start removes them once no container uses them; an open session on the old agentbox image keeps it until a later start. The list of pending removals is `~/.cache/agentbox/retired-images`. Builds keep no intermediate images (`--layers=false`), so a failed build starts over.
- **Sidecars.** Sidecars of MCP modules no longer in `AB_MCP`, and `ab-llm-openai` once its key is gone, are removed on start. Recreated sidecars go with their anonymous volumes (squid declares some).

Images and volumes from before this cleanup existed, or from other projects, are not touched. `podman system df` shows the totals; `podman image prune` removes images without a name, whichever project left them. `podman volume prune` removes unused volumes, in older podman versions named ones too; check `podman volume prune --help` and `podman volume ls --filter dangling=true` first.

The cache volumes grow on purpose, so that sessions do not download the same dependencies again: `ab-cache` (uv cache, Go build cache, per-repo virtualenvs) and `ab-go` (Go modules). With no session running, `podman volume rm ab-cache ab-go` empties them; the next sessions fill them again.

### Uninstall

```bash
agentbox uninstall
```

It lists what it removes and asks before removing anything:

- containers, volumes and networks named `ab-*`. Open sessions end; Claude Code and pi with their logins, session history and caches go with the volumes. Your own containers on `ab-services` ([Local services](#local-services)) are only disconnected, never removed;
- the host services MCP modules started (systemd user services `agentbox-*`, such as the [Tabularis](#tabularis-mcp) bridge);
- agentbox's images: `localhost/agentbox`, `localhost/agentbox-squid` and the sidecar images;
- the cache `~/.cache/agentbox` and its stamps;
- git-guard (`~/.local/bin/git`, only if it is git-guard: your system git takes over again) and `~/.config/environment.d/agentbox.conf`;
- the command `~/.local/bin/agentbox`, its bash completion and the installed versions in `~/.local/share/agentbox`.

Then it asks two more questions, each answered no by default:

- the Podman secrets agentbox and its modules use (`claude_oauth`, `openai_api_key`, the MCP tokens and caller tokens);
- your files in `~/.config/agentbox`: `config.env`, `env/` with passwords, your skills, `AGENTS.md`, local modules.

`agentbox uninstall --yes` removes without asking but keeps the secrets and your files; `--yes --all` removes those too. The repositories you opened in the box are not touched. From a clone, run `./agentbox uninstall` in it; the clone itself stays, delete it yourself.

A setting from `environment.d` stays in your login session until you log out.


```bash
podman logs ab-mcp-grafana        # Grafana auth or URL errors
podman logs ab-mcp-graylog        # 401: bad token, 404: MCP not enabled in Graylog
podman exec ab-egress tail -f /var/log/squid/access.log | grep DENIED   # blocked hosts
podman ps --filter name=ab-       # what is running
podman logs ab-mcp-github         # 401: caller token mismatch, re-register (GitHub, step 3)
podman logs ab-mcp-github-srv     # GitHub API errors
podman stop ab-egress ab-mcp-grafana ab-mcp-graylog ab-mcp-github ab-mcp-github-srv ab-llm-openai   # stop sidecars
```

| Symptom | Likely cause / fix |
|---|---|
| The session cannot read some files of the repo, or all of it (`Permission denied`); `git status` in the box lists files as modified that nobody changed, or `git add` fails | Another podman container mounted them with `:Z`, which gives them an SELinux label private to that container. Typical cause: your own `podman run -v .:/dst:Z ...` in the repo. Use lowercase `:z` (shared label) for code you also open in the box. If the whole repo was relabeled, the next session start restores it; single files stay private, because podman does not relabel a volume it already relabeled with `:z`. Restore them on the host: `chcon -R -t container_file_t -l s0 <path>`. agentbox's own sidecars and sessions mount copies of agentbox's files from the cache, so they do not cause this; an installed version's files are read-only and could not be relabelled anyway |
| `missing podman secrets` | No Claude Code token yet: `agentbox login`. For an MCP module enabled in `config.env`: step 5 of [Setup in detail](#setup-in-detail). |
| Claude shows the login picker or says it is not logged in | See [Token not picked up](#token-not-picked-up). |
| `Unable to connect to Anthropic services` / `ERR_PROXY_TUNNEL` | Squid blocked a required host. The error names it; check the squid log for `DENIED`, add the host in a group in `egress.local.d/` (see [Egress](#egress)); the next start recreates squid. |
| Build or test commands fail to download dependencies | The package registry for your language is not in the allowlist. PyPI is allowed; add others deliberately, each one widens egress. |
| `go: go.mod requires go >= 1.X (running go 1.Y; GOTOOLCHAIN=local)` | The image's Go is older than the project needs. `AB_UPGRADE=1 agentbox` (or raise a pinned `AB_GO_VERSION`). |
| `go` fails to fetch a module with a git or 410/404 error | Private module, or a module not on the public proxy. Vendor it on the host (`go mod vendor`). If the squid log shows `DENIED` for another host, the proxy redirected there; add it deliberately. |
| pi (API key): `OpenAI API error (401)` | Either the API key in `openai_api_key` is invalid, or the sidecar rejected the caller token: `podman logs ab-llm-openai` shows a 401 without an upstream request. If `llm_openai_caller` was recreated, the session was started before that: start a new one. |
| pi (subscription): sign-in or requests fail with `ERR_PROXY_TUNNEL` / 403 | `openai` missing from `AB_EGRESS`. The squid log shows the denied host. |
| pi (subscription): browser shows "can't connect to 127.0.0.1:1455" after approving | Expected, the callback listener is inside the container. Copy the full URL from the address bar and paste it into pi. |
| pi (subscription): requests go to `ab-llm-openai` and fail | `pi/models.json`, which points pi at the sidecar, is used only when the `openai_api_key` secret exists; otherwise pi gets a `models.json` without overrides. If you switched from API key to subscription, `podman secret rm openai_api_key`. |
| pi (subscription): worked before, now fails after an update | Update pi (`AB_UPDATE=1 agentbox pi`). If you are on the legacy "OpenAI Codex" provider, switch to OpenAI → Sign in with ChatGPT. |
| An MCP server is `failed` in `/mcp` | Check `podman logs` of its sidecar. Both agents list only enabled modules, so a failed one has a sidecar that should be running, or (Context7) a host squid should allow. |
| `claude mcp list` does not show grafana, graylog, ... | Expected: the modules' servers come from `--mcp-config`, which `mcp list` ignores. Use `/mcp` in a session. |
| `uv` says a Python version is not available and downloads are set to `never` | That version is not baked into the image. Add it to `AB_PYTHON_VERSIONS` in `config.env` and `AB_UPGRADE=1 agentbox`. |
| Sidecar can't resolve Grafana/Graylog | Internal DNS not visible to containers. Add `--dns <server>` or `--add-host` to the sidecar in `run.sh`. |
| `/mcp` shows a server as failed | Check `podman logs` of the sidecar. |
| `podman logs ab-mcp-graylog` shows `POST /mcp ... 405 59` | The 59-byte body is Graylog's own `HTTP 405 Method Not Allowed` API error, so nginx works but Graylog has no MCP endpoint there. Enable MCP in System → Configurations → MCP, and check the Graylog version is 7.0+. |
| grafana in `/mcp` fails with `403 ... forbidden: host not allowed` | mcp-grafana validates the `Host` header against `--allowed-hosts`. It must include the name Claude uses (`ab-mcp-grafana:8000`). Recreate with `AB_RESTART=1`. |
| nginx sidecar exits on start | nginx resolves `GRAYLOG_URL` at startup. Fix DNS, or use an IP and check TLS/SNI. |
| Context7 fails in `/mcp` or its tools return proxy errors | Squid did not get the modules' hosts: `podman exec ab-egress cat /etc/squid/agentbox-allow.conf` should list `mcp.context7.com`. `AB_RESTART=1 agentbox` recreates squid. |
| Context7 tools return 429 | Anonymous rate limit. Wait, or add an API key through a sidecar (see [Documentation (Context7)](#documentation-context7)). |
| github in `/mcp` fails with 401 | The session has an older `github_mcp_caller` than the sidecar (secret recreated after the session started): start a new session. |
| github in `/mcp` fails with 502 | nginx cannot reach `ab-mcp-github-srv`: check `podman ps` and its logs. If that container was restarted on its own, restart both with `AB_RESTART=1` (nginx caches its IP). |
| GitHub tools fail with 403 / 404 | The PAT lacks the permission, the repository is not selected in it, or an org-owned token is pending approval. Writes to code are expected to fail: Contents is read-only. |
| `git fetch` / `git push` fail inside the box | Expected: GitHub is not reachable from the agent. Run them on the host. |
| `git push -u`, `git remote add` fail | Expected: `.git/config` is read-only. Run these on the host. |
| Git does not work at all inside the box | The repo is a worktree or submodule (`.git` is a file). Its git dir is outside the mount. Run the box on the main checkout. |
| Write errors under `/opt/claude` | Claude Code needs to write to its install dir. Remove `:ro` from the `ab-claude-tools` mount (you lose binary tamper protection). |

### Token not picked up

`run.sh` sets `hasCompletedOnboarding: true` in `~/.claude.json` (inside `ab-claude-home`) before every session, because interactive Claude Code can ignore `CLAUDE_CODE_OAUTH_TOKEN` during first-run onboarding and show the browser login picker instead ([anthropics/claude-code#46259](https://github.com/anthropics/claude-code/issues/46259)). If it still does not work, check the secret itself.

**1. Is the secret intact?** Copying a long token from a terminal often picks up a line break or spaces where the terminal wrapped it.

```bash
podman run --rm --network none --secret claude_oauth,type=env,target=T \
  --entrypoint sh localhost/agentbox -c \
  'printf "length=%s prefix=%.14s\n" "${#T}" "$T"; printf %s "$T" | tr -d "[:graph:]" | od -c | head -2'
```

Expected: prefix `sk-ant-oat01-`, and the `od` output shows **no** characters (only `0000000`). Typical failures:

- prefix looks like a shell command (`read -rsp ...`): the setup commands were pasted as a block, see step 5;
- random-looking string without the `sk-ant-oat01-` prefix: the browser authorization code was stored instead of the token, see step 4;
- `\n` or spaces in the `od` output: the token was broken by terminal wrapping.

Recreate the secret:

```bash
podman secret rm claude_oauth
read -rsp 'Claude token: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create claude_oauth -; echo; unset T
```

**2. Does the token work at all?** Headless mode skips onboarding entirely:

```bash
agentbox . -p "say ok"
```

- Works here but not interactively: an onboarding problem. Check `podman run --rm -v ab-claude-home:/h --entrypoint cat localhost/agentbox /h/.claude.json` for `"hasCompletedOnboarding": true`.
- Fails here too: the token is invalid or expired. Create a new one (setup step 4) and replace the secret.

**3. Stale login state in `ab-claude-home`.** If you once ran `/login` inside the box, stored credentials can take precedence. Run `/logout` in a session, or remove `/home/node/.claude/.credentials.json` from the volume.

## Reference

### Configuration reference

| Variable | Default | Meaning |
|---|---|---|
| `AB_HOME` | `~/.config/agentbox` | Directory with your files. See [Your files](#your-files) |
| `AB_CONFIG` | `<AB_HOME>/config.env` | Settings file. All variables in this table except `AB_AGENT`, `AB_UPDATE`, `AB_RESTART`, `AB_UPGRADE` can be set there; a module's settings only while the module is in `AB_MCP` |
| `AB_MCP` | unset | MCP modules to enable, space- or comma-separated, e.g. `grafana graylog github`. `context7` is always on. See [MCP servers](#mcp-servers) |
| `AB_EGRESS` | `anthropic openai pypi go` | Egress groups to enable, space- or comma-separated, from `egress.local.d/` or `egress.d/`; empty enables none. See [Egress](#egress) |
| `GRAFANA_URL` | unset | Setting of the `grafana` module: Grafana base URL (needs the `grafana_sa` secret) |
| `GRAYLOG_URL` | unset | Setting of the `graylog` module: Graylog base URL (needs the `graylog_basic` secret) |
| `AB_UPDATE` | unset | `1` forces a Claude Code update |
| `AB_UPDATE_EVERY` | `21600` | Seconds between automatic agent updates, and between update checks for sidecar images and vendored skills |
| `GH_TOOLSETS` | `context,repos,issues,pull_requests,actions` | Setting of the `github` module: toolsets, enforced by nginx |
| `TABULARIS_CMD` | `tabularis` | Setting of the `tabularis` module: the command that runs Tabularis on the host; `--mcp` is appended. Letters, digits, spaces and `_./:=+-` only |
| `WOODPECKER_URL` | unset | Setting of the `woodpecker` module: Woodpecker's base URL, without `/api` (needs the `woodpecker_token` secret) |
| `WOODPECKER_CA` | unset | Setting of the `woodpecker` module: a CA certificate file for an https Woodpecker signed by your own CA |
| `TABULARIS_PORT` | `47821` | Setting of the `tabularis` module: supergateway's port on `127.0.0.1` |
| `AB_SKILLS` | unset | Skill sources to enable, space- or comma-separated, from `skills.local.d/` or `skills.d/`. See [Skills](#skills) |
| `AB_SKILLS_DIR` | `<AB_HOME>/skills` | Personal skills directory, mounted read-only |
| `AB_GRAPHIFY_EXTRAS` | unset | graphify extras baked into the image, e.g. `[terraform]`. A change rebuilds the image at the next start. See [Graphify](#graphify) |
| `AB_TRIVY` | unset | `1`: Trivy in the image, its database kept current outside the session. A change rebuilds the image at the next start. See [Trivy](#trivy) |
| `AB_PYTHON_VERSIONS` | `3.12 3.13 3.14` | Python interpreters baked into the image. A change rebuilds the image at the next start. See [Python](#python) |
| `AB_GO_VERSION`, `AB_GOLANGCI_LINT_VERSION` | `1.26`, latest | Go and golangci-lint in the image; empty = latest release. A change rebuilds the image at the next start. See [Go](#go) |
| `AB_SERVICES` | unset | Your own containers (space- or comma-separated names) attached to the `ab-services` network; the session reaches them by name. See [Local services](#local-services) |
| `AB_FORWARD` | unset | Services outside the box, `name=host:port`, space- or comma-separated; the session reaches them by name. Also per repo in `<env dir>/<repo dir name>.conf`. See [Test servers](#test-servers) |
| `AB_ENV_DIR` | `<AB_HOME>/env` | Per-project environment files, `<repo dir name>.env`. See [Per-project environment](#per-project-environment) |
| `AB_AGENT` | `claude` | `pi` runs pi instead of Claude Code (what `agentbox pi` sets). `shell` runs bash in the same box instead of an agent, with its own home volume `ab-shell-home`; arguments go to bash: none for an interactive shell, a script, or `-c '...'` |
| `AB_UPGRADE` | unset | `1` pulls sidecar images, rebuilds the base image, updates Claude Code, recreates sidecars |
| `AB_RESTART` | unset | `1` recreates all sidecars. Rarely needed: a sidecar is recreated by itself when its settings, image tag, mounted files (nginx templates, `squid.conf`, egress hosts) or Podman secrets change |
| `AB_CHECK_UPDATES` | `1` | `0` skips the check for newer sidecar images and vendored skills before a session. See [Update check](#update-check) |

Sidecars are started once and reused. The next start recreates a sidecar whose settings, image tag, mounted files or Podman secrets (a secret made anew, such as a renewed token) changed, and removes those of modules no longer in `AB_MCP`. To recreate them all anyway:

```bash
AB_RESTART=1 agentbox .
```

### Files

| File | Purpose |
|---|---|
| `agentbox` | The command `install.sh` links into `~/.local/bin`: `agentbox [repo]`, `pi`, `shell`, `login`, `setup`, `version`, `update`, `rollback`, `uninstall`. See [Releases](#releases) |
| `install.sh`, `release.sh` | Install an unpacked release; publish one (maintainers). See [Releases](#releases) |
| `VERSION`, `CHANGELOG.md`, `release/allowed_signers` | The release version (written by `git archive`), the changes per release, the keys updates must be signed with |
| `run.sh` | Entry point: the steps in order (config, image, updates, sidecars, session); the steps themselves are in `lib/` |
| `lib/*.sh` | The steps of `run.sh`: settings, agent, sidecars, MCP modules, local services, skills, session |
| `mcp/<name>/` | MCP server modules, enabled with `AB_MCP`: `mcp.sh` plus files such as nginx templates. See [MCP servers](#mcp-servers) |
| `config.env.example` | Settings template; copy to `~/.config/agentbox/config.env` |
| `pi.sh` | Same as `run.sh`, with pi as the agent (`AB_AGENT=pi`) |
| `pi/models.json` | pi configuration: model endpoint for API-key mode; a copy, made at each start in `~/.cache/agentbox/session/pi/`, is mounted read-only |
| `pi/llm-openai.conf.template` | nginx config for the OpenAI sidecar (pi with an API key): caller auth, API key injection |
| `Containerfile` | Base image (`node:24-trixie-slim`, Debian 13, Node.js 24 LTS): node, git, ripgrep, fd, make, gcc, uv with preinstalled Python versions, Go, golangci-lint, graphify |
| `Containerfile.squid` | The egress proxy's image: Debian's squid, built here like the base image |
| `squid.conf` | Egress proxy settings and access rules. The allowed hosts come from a generated file it includes |
| `egress.d/<name>.conf` | Egress groups (PyPI, Go modules, ...), enabled with `AB_EGRESS`. See [Egress](#egress) |
| `agents/AGENTS.md.example` | Template for `~/.config/agentbox/AGENTS.md`: optional personal instructions for both agents in every repo, mounted read-only (Claude Code: `~/.claude/CLAUDE.md`, pi: `~/.pi/agent/AGENTS.md`) |
| `claude/statusline.py` | Claude Code status line (context use, subscription limits, cost), mounted read-only as a copy from `~/.cache/agentbox/session/claude/`; used unless you set your own `statusLine`. See [Status line](#status-line) |
| `skills.d/<name>.conf` | Skill sources (git repositories of skills), enabled with `AB_SKILLS`. See [Skills](#skills) |
| `completions/agentbox.bash` | Tab completion for the `agentbox` command in bash, linked into `~/.local/share/bash-completion/completions/` at install and at every update |
| `git-guard` | Host-side git wrapper, installed as `~/.local/bin/git`: refuses repositories whose `.git` a session redirected. See [Git on the host](#git-on-the-host) |
| `sync-skills.sh` | Host-side: installs a skills repository into your `skills/` (flattened); run by `run.sh` for the sources in `AB_SKILLS` |
| `check-updates.sh` | Host-side, run by `run.sh` at most every 6 hours: newer sidecar images and vendored skills, with an offer to update |
| `tests/run.sh` | Tests for `run.sh`, `check-updates.sh` and `sync-skills.sh` with a podman stand-in. See [Tests](#tests) |

#### Your files

Your settings and data live apart from the code, in `~/.config/agentbox/` (`AB_HOME` moves it). The code can then be replaced by a new version or a fresh clone without touching them, and a session that has agentbox's own code open as its repo does not see them. In this README, `config.env`, `env/` and the others below mean the ones there.

| File | Purpose |
|---|---|
| `config.env` | Settings, from `config.env.example` |
| `env/` | Optional. Per-project environment files, `<repo dir name>.env`, and per-project settings, `<repo dir name>.conf` (`AB_FORWARD`, see [Test servers](#test-servers)) |
| `skills/` | Optional. Personal skills, mounted read-only into the agent. `skills/.sources/` holds what `sync-skills.sh` installed from where |
| `AGENTS.md` | Optional. Personal instructions for both agents, from `agents/AGENTS.md.example` |
| `mcp.local/<name>/` | Your own MCP modules; one with the name of a module in `mcp/` replaces it |
| `skills.local.d/<name>.conf` | Your own skill sources |
| `egress.local.d/<name>.conf` | Your own egress groups |
| `dbhub.toml` | Optional. The databases of the `dbhub` module, with their passwords; mode 600. See [DBHub (MCP)](#dbhub-mcp) |
| `pi-extensions/` | pi extensions you choose to allow, mounted read-only. Created empty on the first start of pi |

`run.sh` refuses to mount a repo that is, contains or lies inside agentbox's code, any installed version (`~/.local/share/agentbox`; `agentbox rollback` would run it), git-guard (`~/.local/bin/git`) or these files: a session could otherwise change code that runs on your host, or read your passwords. To work on agentbox itself, open a separate clone of it.

Older versions kept these files next to the code (`agents/AGENTS.md` for `AGENTS.md`, `pi/extensions/` for `pi-extensions/`). While any is still there, `run.sh` stops before starting anything and prints the commands that move it.

### Tests

```bash
./tests/run.sh            # all tests
./tests/run.sh test_mcp_  # tests whose name starts with test_mcp_
```

They need no podman, network or registry: `tests/stub/podman` stands in for podman and records every call, fake `curl` and `git ls-remote` stand in for registries and GitHub, and `sync-skills.sh` clones a local repository. Each test works on a copy of agentbox's code in a scratch directory, never on your `config.env` or `skills/`. They check what `run.sh` asks podman to do (sidecars, secrets, the session's mounts and arguments), the generated MCP configs, and the error paths. Requires bash 4+ and git; python3 for the JSON checks, skipped without it.

Run them after changing `run.sh`, `lib/`, a module in `mcp/`, `check-updates.sh` or `sync-skills.sh`. A new module or setting deserves a test next to the existing ones in `tests/run.sh`.

#### Escape checks

`tests/run.sh` checks what `run.sh` asks podman to do, not what a session can actually reach. `tests/escape.sh` does that from the inside, in a real box. No agent is needed: `AB_AGENT=shell` runs bash in the same box instead.

```bash
agentbox shell ~/src/agentbox tests/escape.sh   # a clone of agentbox as the repo
```

In an agent's session it works too (`bash tests/escape.sh` with the agentbox repo open).

It tries what an agent under prompt injection would: direct connections and DNS around the proxy, the host and the network gateways, disallowed hosts, IP addresses and other ports through the proxy, the sidecars through the proxy and without their caller tokens, container runtime sockets, credentials in the home directory and the environment, privileges, and writes to everything mounted read-only. PASS means the attempt failed; FAIL is a hole, and the exit status is 1. WARN lines are not holes by themselves. It changes nothing: connection attempts and reads, plus a scratch file it removes again.

Run it after changes to networks, squid, sidecars or the session's mounts, and on a new host. `ESCAPE_FORBIDDEN` and `ESCAPE_REACHABLE` (space-separated `host:port`) add targets that must not, or must, be reachable.

#### CI

GitHub Actions runs both on every push to `main` and every pull request:

- `.github/workflows/checks.yml`: `tests/run.sh` and `shellcheck`, about a minute.
- `.github/workflows/box.yml`: a real box on the runner's rootless podman: builds the image, starts squid and two repos' `AB_FORWARD` sidecars, and runs `tests/escape.sh` in a session of one repo, with the other repo's forward sidecar as a target that must stay out of reach. Also daily, to catch breakage from outside (new squid or nginx images, podman or Ubuntu updates on the runner).

The workflows have read-only access to the repo and no secrets; actions are pinned to a commit, not a tag.

### Not yet verified

These parts are assembled from documentation and tests against fake upstreams, but have not been run end to end:

- pi through the OpenAI sidecar against the real OpenAI API. The chain pi → nginx (caller check, key injection) → upstream was tested with a fake upstream.
- pi's *Sign in with ChatGPT* through squid with the pasted callback URL, and token refresh with `PI_OFFLINE=1` set.
- Context7 through squid from pi (it works from Claude Code).
