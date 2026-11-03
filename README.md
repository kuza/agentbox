# agentbox

[![Release](https://img.shields.io/github/v/release/kuza/agentbox)](https://github.com/kuza/agentbox/releases/latest)
[![License](https://img.shields.io/github/license/kuza/agentbox)](LICENSE)
[![Linux, rootless Podman](https://img.shields.io/badge/Linux-rootless%20Podman-892CA0?logo=podman&logoColor=white)](#requirements)
[![Checks](https://github.com/kuza/agentbox/actions/workflows/checks.yml/badge.svg)](https://github.com/kuza/agentbox/actions/workflows/checks.yml)
[![Box](https://github.com/kuza/agentbox/actions/workflows/box.yml/badge.svg)](https://github.com/kuza/agentbox/actions/workflows/box.yml)
[![Scan](https://github.com/kuza/agentbox/actions/workflows/scan.yml/badge.svg)](https://github.com/kuza/agentbox/actions/workflows/scan.yml)

Run [Claude Code](https://code.claude.com/docs), or the [pi](https://pi.dev) coding agent with OpenAI models (a ChatGPT subscription or an API key), in an isolated rootless Podman container that can reach only:

- the model API (Anthropic for Claude Code; OpenAI for pi),
- MCP servers for **Context7** (library documentation) and, each optional, **Grafana** (with **Prometheus** through Grafana), **Graylog**, **GitHub**, **Woodpecker CI** (read-only) and **Tabularis** (your databases through the Tabularis desktop app).

agentbox mounts no host credentials into the agent container. All service tokens (Grafana, Graylog, GitHub, Woodpecker) are only in sidecar containers that the agent cannot read. Database passwords stay with Tabularis on the host. You do `git push` on the host.

## Contents

- **[Getting started](#getting-started):** [Quick start](#quick-start) · [Requirements](#requirements) · [Setup in detail](#setup-in-detail) · [Daily usage](#daily-usage)
- **[How it works](#how-it-works):** [Architecture](#architecture) · [Security model](#security-model) · [Git on the host](#git-on-the-host) · [Egress](#egress)
- **[Agents](#agents):** [pi (OpenAI)](#pi-openai) · [Memory and personal instructions](#memory-and-personal-instructions) · [Status line](#status-line) · [Skills](#skills)
- **[Integrations](#integrations):** [MCP servers](#mcp-servers) · [GitHub (MCP)](#github-mcp) · [Woodpecker (MCP)](#woodpecker-mcp) · [Tabularis (MCP)](#tabularis-mcp) · [DBHub (MCP)](#dbhub-mcp) · [Remote browser (bb4)](#remote-browser-bb4) · [Documentation (Context7)](#documentation-context7)
- **[In the box](#in-the-box):** [Python](#python) · [Go](#go) · [Graphify](#graphify) · [Trivy](#trivy)
- **[Your projects](#your-projects):** [Local services](#local-services) · [Test servers](#test-servers) · [Per-project environment](#per-project-environment)
- **[Maintenance](#maintenance):** [Releases](#releases) · [Updates](#updates) · [Disk space](#disk-space) · [Uninstall](#uninstall) · [Troubleshooting](#troubleshooting) · [Token not picked up](#token-not-picked-up)
- **[Reference](#reference):** [Configuration reference](#configuration-reference) · [Files](#files) · [Tests](#tests) · [Not yet verified](#not-yet-verified)

## Getting started

### Quick start

You need Linux with rootless Podman 4.x or newer on the netavark backend (`podman info --format '{{.Host.NetworkBackend}}'` prints `netavark`). You also need a Claude subscription.

**1. Install a release** and check its signature (the key is in [Releases](#releases)):

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

If you install git-guard, `install.sh` also writes `~/.config/environment.d/agentbox.conf`. This file puts `~/.local/bin` first in `PATH` for your full desktop session ([Git on the host](#git-on-the-host)). Log out and log in again. Then make sure that `command -v git` prints `~/.local/bin/git`.

**2. Sign in to Claude:**

```bash
agentbox login
```

This command builds the image (a few minutes the first time) and installs Claude Code in the box. Then it starts `claude setup-token` in the box. Open the URL that it prints and sign in. Paste the code from the browser back into the terminal. Then paste the token that it prints (`sk-ant-oat01-...`) at the hidden prompt.

agentbox stores the token as the Podman secret `claude_oauth`. When the token expires, run `agentbox login` again. If you start `agentbox` for the first time without a token, it also offers this step.

**3. Work:**

```bash
cd ~/src/your-repo
agentbox          # Claude Code in the box; agentbox pi for pi, agentbox shell for bash
```

Then use `agentbox setup` to enable what you need: MCP servers for Grafana, Graylog, GitHub or Tabularis, skill sources, the hosts that the agent can reach, Trivy ([Setup menu](#setup-menu)). These sections give more detail: MCP servers for Grafana, Graylog, GitHub or Tabularis ([MCP servers](#mcp-servers)), skills ([Skills](#skills)), your test databases ([Test servers](#test-servers)). `agentbox update` installs new releases. `agentbox uninstall` removes all of agentbox ([Uninstall](#uninstall)).

### Requirements

- Linux with rootless Podman **4.x or newer** and the **netavark** network backend
  ```bash
  podman --version
  podman info --format '{{.Host.NetworkBackend}}'   # must print: netavark
  ```
- For the optional Grafana and Graylog MCP servers: network access from the host to them, and **Graylog 7.0+** for its built-in MCP endpoint (Graylog marks this endpoint as experimental)
- A Claude subscription or an Anthropic account for `claude setup-token`

### Setup in detail

[Quick start](#quick-start) does all of this with `install.sh` and `agentbox login`. This section gives the long form. It tells what each step does, the optional parts (service accounts and secrets for the MCP servers), and the manual procedure.

#### 1. Install and configure

Install a release (below). To work on agentbox itself, clone the repository and run `./run.sh` from the clone. That clone must not be the copy that you open in the box; [Releases](#releases) tells why.

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

`install.sh` does these steps:

- It puts the release into `~/.local/share/agentbox/versions/`.
- It links `~/.local/bin/agentbox` to the release.
- It creates `~/.config/agentbox/config.env` from the example.
- It offers to install [git-guard](#git-on-the-host). It never installs git-guard over a `~/.local/bin/git` of your own.

After that, `agentbox update` installs newer releases and verifies their signatures itself.

Edit `config.env`. Choose the MCP servers with `AB_MCP`, for example `AB_MCP=grafana graylog`. Set the values that those modules need, such as `GRAFANA_URL` / `GRAYLOG_URL`. Use base URLs only, without `/api` or `/api/mcp`; agentbox removes these trailing parts anyway.

Context7 is always on. Skip the steps below for the servers that you do not use. See [MCP servers](#mcp-servers).

```bash
$EDITOR ~/.config/agentbox/config.env
cp ~/.local/share/agentbox/current/agents/AGENTS.md.example ~/.config/agentbox/AGENTS.md   # optional: personal instructions for the agents, see Memory and personal instructions
```

agentbox parses `config.env`, but does not execute it. The file accepts only known keys, and updates of `run.sh` do not change it. Environment variables override it. `AB_CONFIG=/path/to/file` selects a different file, for example one file for each environment. If an enabled MCP module does not have its settings or secrets (step 5), the script stops with an error that names them.

The agent can reach the network only through squid. Squid allows the hosts of the enabled MCP modules and of the egress groups in `AB_EGRESS`. By default, these groups are:

- the Anthropic hosts that Claude Code requires (see Claude Code's [network access requirements](https://code.claude.com/docs/en/network-config#network-access-requirements)),
- `auth.openai.com` and `api.openai.com`, for pi with a ChatGPT subscription,
- PyPI,
- the Go module proxy.

See [Egress](#egress). Squid does **not** allow these hosts, on purpose:

| Host | Effect of the block |
|---|---|
| `mcp-proxy.anthropic.com` | No claude.ai connectors (the environment also disables them) |
| `registry.npmjs.org`, `github.com` | You cannot install plugins in the session |
| `raw.githubusercontent.com` | `/release-notes` does not load |
| `code.claude.com`, `claude.com` | No access to the built-in documentation |
| `*.frame.claudeusercontent.com` | Claude Code cannot read artifacts (the environment also disables this) |
| Datadog intake hosts | No telemetry (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` also disables it) |

#### 2. Create read-only service accounts

Do this step only for the MCP servers that you enable.

- **Grafana:** Administration → Users and access → Service accounts → create an account with the role **Viewer** → *Add service account token*.
- **Graylog:** Create a dedicated user with a read-only role. Then go to System → Users and Teams → *Tokens* → create an API token. Enable MCP in the Graylog settings.

#### 3. Create networks, build the image, install Claude Code

`agentbox login` does steps 3 and 4 and the `claude_oauth` part of step 5 for you. It asks you for input while it runs. The manual procedure:

```bash
podman network create --internal ab-internal
podman network create ab-egress
podman build -t localhost/agentbox -f Containerfile .

podman run --rm --network ab-egress --userns=keep-id:uid=1000,gid=1000 \
  -v ab-claude-tools:/opt/claude --entrypoint npm localhost/agentbox \
  install -g --prefix /opt/claude @anthropic-ai/claude-code@latest
```

`run.sh` also does all of this automatically. But `run.sh` does not start until the secrets from step 5 exist. Thus, do these steps manually the first time.

#### 4. Get a Claude token

Run this command in the box, so that you do not need Claude Code on the host:

```bash
podman run --rm -it --network ab-egress --userns=keep-id:uid=1000,gid=1000 \
  -v ab-claude-tools:/opt/claude:ro localhost/agentbox setup-token
```

Open the printed URL in a browser and sign in. Paste the code that the browser shows **back into this terminal**. `setup-token` then exchanges the code and prints the long-lived token.

> **Code vs. token.** The browser shows a short-lived *authorization code*. That is not the token. After that, `setup-token` prints the token in the terminal. The token always starts with `sk-ant-oat01-`. Put only the token into the secret. If you store the code, you get `401 Invalid bearer token`.
>
> If you get `OAuth error: Request failed with status code 400` in this step, the code was rejected. The code expired, the paste was not complete, or the code was used before. Run `setup-token` again. Paste the new code immediately.

#### 5. Create Podman secrets

With `read -s`, the tokens do not go into your shell history.

> **Run these commands one at a time.** Paste one line and press Enter. Then paste only the token at the prompt. If you paste the full block at once, each `read` uses the next pasted command line as its input. Then the secrets contain shell commands instead of tokens.

```bash
read -rsp 'Claude token: '  T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create claude_oauth -; echo
# only for the grafana / graylog modules:
read -rsp 'Grafana token: ' T && printf '%s' "$T" | podman secret create grafana_sa -; echo
read -rsp 'Graylog token: ' T && printf '%s:token' "$T" | base64 -w0 | podman secret create graylog_basic -; echo
unset T
podman secret ls
```

The Graylog secret is `base64("<token>:token")`. The literal word `token` is the password, because Graylog expects this format.

#### 6. MCP servers: nothing to register

At each start, `run.sh` gives both agents the servers of the modules in `AB_MCP`, plus Context7. Claude Code gets them through `--mcp-config`, and pi gets them through its `mcp.json`. `run.sh` generates the caller tokens as Podman secrets. These tokens get into the session only as environment variables. See [MCP servers](#mcp-servers).

`claude mcp list` does not show these servers. To see them, use `/mcp` in a session. Maybe you registered servers manually before (`claude mcp add` for grafana, graylog, github, context7). If the name and URL of such a server match a module, the next start removes that server. Thus the server does not appear twice.

There is no separate Prometheus server. `mcp-grafana` has tools that query the Prometheus datasources configured in Grafana. If these tools are not sufficient, add a module.

#### 7. Verify

```bash
agentbox ~/src/myrepo
```

In the session:

- `/mcp` shows `context7` and the servers in `AB_MCP` as connected.
- Ask Claude to run `curl -sI https://example.com`. The expected result is **403** from squid.
- Ask Claude to run `env | grep -iE 'token|key|pass'`. The expected result is `CLAUDE_CODE_OAUTH_TOKEN` and the caller tokens `AB_MCP_TOKEN_*`. The caller tokens give access only to the sidecars.
- If you enabled the MCP servers, ask for the latest errors from Graylog and the `up` status of the Prometheus targets. The answers show that the MCP servers reach their backends.

### Daily usage

```
agentbox [repo-dir] [claude args...]        Claude Code
agentbox pi [repo-dir] [pi args...]         pi
agentbox shell [repo-dir] [bash args...]    bash in the same box, no agent
agentbox setup                              a menu for config.env (below)
```

If the first argument is a directory that exists, agentbox mounts it as the repo. If not, agentbox mounts the **current directory** and gives all arguments to the agent. agentbox prints which directory it mounts. It refuses to mount agentbox's own code, the installed versions, git-guard or your files in `~/.config/agentbox`.

```bash
cd ~/src/myrepo && agentbox                      # current directory
agentbox ~/src/myrepo                            # explicit repo
agentbox --dangerously-skip-permissions          # current directory + claude flags
agentbox ~/src/myrepo -p "say ok"                # explicit repo + claude args
```

agentbox resolves relative paths against **your** current directory. If the first argument is the name of a directory in your current directory, agentbox uses that directory as the repo. If a claude subcommand has such a name, give the repo explicitly: `agentbox . <subcommand>`. The words `pi`, `shell`, `login`, `setup`, `version`, `update`, `rollback` and `uninstall` are agentbox's own commands. To open a directory with such a name, give it as a path, for example `./pi`.

`agentbox` runs `run.sh` from the installed version. This README uses the name `run.sh` where it describes what occurs at a start. Put settings in the environment in front of the command, as in `AB_UPGRADE=1 agentbox`.

In bash, the Tab key completes agentbox's commands, the repo directory and the options of `update` and `uninstall`. The installed version links its completion file as `~/.local/share/bash-completion/completions/agentbox`. The `bash-completion` package loads this file. If you have your own file there, agentbox does not change it.

Several sessions can run in parallel. Each session gets its own `ab-claude-<pid>` container, and all sessions share the sidecars.

During the start, agentbox prints warnings (`agentbox: warning: ...`). Examples are an MCP module that agentbox left out, a git on the host that is not git-guard, and an update that failed. The agent's screen would push these warnings out of view. Thus, at a terminal, agentbox shows them again immediately before the session and asks `start the session? [Y/n]`. Enter starts the session, and `n` stops agentbox there.

agentbox does not ask this question without a terminal, for an agent run with `-p` or `--print`, or for `agentbox shell` with a command. To disable the question in all cases, set `AB_WARNINGS_ASK=0` in `config.env`.

agentbox mounts the repo at `/work/<repo dir name>`. This path is also the working directory. Claude Code keeps per-project state (memory, session history, `/resume`, project permissions) by that path. Thus each repo gets its own state, but two repos with the same directory name share it.

#### Copying out of a session

The box has no access to the clipboard of your desktop (no X11 or Wayland socket, no `xclip` or `wl-copy`). Text gets to your clipboard only through your terminal. Claude Code sends the text as an OSC 52 escape sequence (`/copy` for the last response, or a mouse selection in the session). If the terminal supports and allows this, the terminal puts the text into the clipboard.

- **kitty** works without changes. Its default `clipboard_control` lets programs write the clipboard, and asks before they read it. To use the kitty selection instead of the Claude Code selection, hold **Shift** while you select.
- **Other terminals:** Make sure that the terminal supports OSC 52 and allows programs to write the clipboard. Some terminals need a setting to enable this, and some do not support it at all. Claude Code says "Copied to clipboard" in all cases. Thus, do a test paste.
- **tmux or screen** between Claude Code and the terminal must forward OSC 52 to the terminal (tmux: `set-clipboard`).

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

The menu lists all MCP modules, skill sources and egress groups: the shared ones and yours (`mcp.local/`, `skills.local.d/`, `egress.local.d/`, marked "(yours)"). It shows which entries are enabled, and it also lists the other settings. Under each module, the menu shows the settings of the module with their values. A value shows "(default)" if the setting is not set, and "NEEDED" if the module cannot start without a value. A value shows "(environment)" if your environment sets the setting. The menu also shows the Podman secrets of the module: stored, MISSING, or new (typed, but not saved yet).

- A number enables or disables an entry, or asks for a value. For a value, Enter keeps the current value, and `-` unsets it.
- When you enable a module, the menu asks for its settings. It also asks, with hidden input, for the secrets that the module does not have. The prompt tells what to type, and the module changes that input into the secret (the Graylog token becomes its basic-auth value). If you disable the module again before you save, the menu discards what you typed for it.
- `e <number>` asks for all settings and secrets of a module, enabled or disabled. It does not enable or disable the module. For a stored secret, a new value replaces it, and Enter keeps it. Use this to enter a renewed token.
- `s` saves. The menu edits `config.env` in place and keeps your comments and the order of its lines. If `config.env` is a link, it stays a link, and the menu edits the file that the link points to. The menu keeps the previous file as `config.env.bak` and stores the secrets. `q` quits. If some changes are not saved, `q` asks first.

Tokens never go into `config.env`. The menu only edits the file. The next `agentbox` start applies the changes: it starts or removes sidecars, changes the squid list, installs skills, and rebuilds the image. Sessions that are open keep the configuration that they started with. If your environment also sets a setting, the environment value overrides the file. The menu shows the names of such settings.

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
                      ├──► ab-mcp-bb4 ──► ab-mcp-bb4-devtools ──► remote browser (CDP WebSocket)
                      │    (nginx, caller auth) (chrome-devtools-mcp)
                      └──► ab-mcp-tabularis ──► ab-mcp-tabularis-relay ──► supergateway ──► tabularis --mcp
                           (nginx, caller auth,  (socat, host network,     (host service,
                            unix socket)          unix socket → loopback)   127.0.0.1)
```

| Container | Networks | Holds secrets | Purpose |
|---|---|---|---|
| `ab-claude-<pid>` | `ab-internal` | Claude OAuth token only | Claude Code session, one per run |
| `ab-egress` | `ab-internal`, `ab-egress` | none | Squid forward proxy with a domain allowlist |
| `ab-mcp-grafana` | `ab-internal`, `ab-egress` | Grafana service account token | Official `grafana/mcp-grafana`, streamable HTTP on `:8000/mcp`, bearer-token caller auth, Host allowlist, `--disable-write`, usage stats off. Module `grafana` |
| `ab-mcp-graylog` | `ab-internal`, `ab-egress` | Graylog API token | nginx reverse proxy to the built-in MCP endpoint of Graylog: checks the caller token and replaces it with the Graylog `Authorization`. Module `graylog` |
| `ab-mcp-github` | `ab-internal`, `ab-egress` | GitHub PAT | nginx: checks the caller token, injects the PAT, pins toolsets and lockdown mode. Module `github` |
| `ab-llm-openai` | `ab-internal`, `ab-egress` | OpenAI API key | nginx: checks the caller token, injects the API key, forwards to `api.openai.com` with certificate verification. Only for pi in API-key mode |
| `ab-mcp-github-srv` | `ab-egress` **only** | none | Official `github-mcp-server` in HTTP mode. The agent cannot reach it. Module `github` |
| `ab-mcp-woodpecker` | `ab-internal`, `ab-egress`, `ab-mcp-woodpecker` | Woodpecker token, bridge key | nginx: on `:8080`, checks the caller token and sends the bridge key to the server. On `:8081`, lets the server read Woodpecker (GET and HEAD only, checks the bridge key, injects the token, verifies the certificate). Module `woodpecker` |
| `ab-mcp-woodpecker-srv` | `ab-mcp-woodpecker` **only** (`--internal`, no outside DNS) | none | `rtuszik/woodpecker-mcp` in read-only mode. It can reach nginx and nothing else, not even squid. The agent cannot reach it. Module `woodpecker` |
| `ab-mcp-bb4` | `ab-internal`, `ab-egress` | bb4 bridge key | nginx: checks the caller token, forwards to `ab-mcp-bb4-devtools` with the bridge key. Module `bb4` |
| `ab-mcp-bb4-devtools` | `ab-egress` **only** | bb4 bridge key | chrome-devtools-mcp behind supergateway, built here. It connects to the DevTools WebSocket of the remote browser. The agent cannot reach it. Module `bb4` |
| `ab-mcp-dbhub` | `ab-internal`, `ab-egress` | Database passwords (from your `dbhub.toml`, through a mode-600 copy in the cache) | `bytebase/dbhub`: bearer-token caller auth, Host allowlist, read-only tools only. Module `dbhub` |
| `ab-mcp-tabularis` | `ab-internal` **only** | Tabularis bridge key | nginx: checks the caller token, replaces it with the bridge key, forwards to the unix socket of the relay. Module `tabularis` |
| `ab-mcp-tabularis-relay` | host network | none | socat: forwards the unix socket in the volume `ab-mcp-tabularis-sock` to supergateway on `127.0.0.1`. The agent cannot reach it. Module `tabularis` |

The `tabularis` module also runs a program on the host, outside all containers: the systemd user service `agentbox-mcp-tabularis` (see [Tabularis (MCP)](#tabularis-mcp)).

Volumes:

| Volume | Mounted in agent as | Contents |
|---|---|---|
| `ab-claude-home` | `/home/node` (rw), Claude Code sessions only | Claude Code settings, session history, MCP registrations |
| `ab-pi-home` | `/home/node` (rw), pi sessions only | pi settings, sessions, ChatGPT sign-in (`~/.pi/agent/auth.json`) |
| `ab-cache` | `/home/node/.cache` (rw), both agents | uv cache, Go build cache, per-repo Python virtualenvs |
| `ab-go` | `/home/node/go` (rw), both agents | Go module cache, `go install` binaries |
| `ab-pi-tools` | `/opt/pi` (**ro**) | pi installation |
| `ab-claude-tools` | `/opt/claude` (**ro**) | Claude Code installation |

Each agent has its own home volume. Thus, one agent cannot read the credentials of the other agent or change the configuration of the other agent. For example, a pi session cannot plant a hook in `~/.claude/settings.json`. The two agents share the two cache volumes, because these volumes hold no configuration or credentials. They hold only downloaded packages and build output.

\* The agent container holds `CLAUDE_CODE_OAUTH_TOKEN`. Technically, the agent can read it. But the token gives access only to Claude, and it can go only to the hosts in the egress allowlist.

### Security model

**What is isolated**

- **Network.** The agent is on a `--internal` network. Its only path to the outside is the squid proxy. Squid allows the Context7 documentation server (`mcp.context7.com`), which the setup needs, and the [egress groups](#egress) that you enable. By default, these groups are the three Anthropic hosts that Claude Code needs (`api.anthropic.com`, `platform.claude.com`, `claude.ai`), the OpenAI sign-in for pi, and package sources for Python and Go. All other hosts, GitHub too, get a 403. External host names do not resolve in the session (`--dns 127.0.0.1`), so DNS queries cannot send data to the outside either; container names resolve.
- **claude.ai connectors.** `ENABLE_CLAUDEAI_MCP_SERVERS=false` stops Claude Code from loading the MCP connectors that you configured in your claude.ai account (mail, chat, drives, ...). Only the MCP servers that are registered in the box are available.
- **Credentials.** The agent cannot see the host environment, `~/.ssh`, `~/.aws`, `~/.kube` or similar data. The Grafana, Graylog and GitHub tokens are only in their sidecars, as Podman secrets.
- **The agent's own binary.** A separate short-lived container installs Claude Code into `ab-claude-tools`. This volume is mounted read-only, so the agent cannot change its own executable.
- **Host-side git execution.** `.git/hooks`, `.git/config` and `.git/modules` are mounted read-only. `.git` itself is a separate mount, so the agent cannot rename and replace it. The `.git` file of a worktree or submodule is read-only. If these were writable, the agent could plant a hook or `core.fsmonitor` that runs **on the host** the next time you run `git commit` or `git status`. The rest of `.git` stays writable for commits, branches and worktrees. [git-guard](#git-on-the-host) on the host covers the gaps that this leaves open.
- **Process hardening.** `--cap-drop=ALL`, `no-new-privileges`, rootless Podman.

**What is NOT isolated**

- **The rest of `.git` is writable, and git on the host trusts it.** The agent can write `.git/commondir`, or point the `.git` file of a worktree at a directory that the agent made. Then git on the host uses the config and hooks of that directory. The next `git status` then runs the command of the agent outside the box, also the `git status` that your editor runs automatically. **Install [git-guard](#git-on-the-host)**. It refuses such a repository before git runs. Without git-guard, this path is open.
- The repository is mounted read-write. The agent can change all files in it. Before you run anything from the repo on the host (`Makefile`, scripts, `.envrc`, CI config, editor tasks), review the diffs.
- MCP tools use the permissions of their service accounts. **Isolation does not limit what the tokens can do**. Thus, make the tokens read-only (see step 2). The same applies to Tabularis. The agent runs SQL with your saved connections, and only the read-only mode and the approvals of Tabularis limit it.
- Squid filters by host name and does not examine TLS. A broad allowlist entry (for example, a full git hosting service) is a possible exfiltration path.
- The container uses the same kernel as the host, as all containers do. The session has no capabilities and has a seccomp filter. But the session can still create new user namespaces (`unshare -Ur`), which some kernel privilege-escalation exploits use. Without a custom seccomp profile, podman cannot disable this per container. Keep the host kernel up to date. `tests/escape.sh` reports this as a WARN.
- "No credentials in the box" stops the agent from using **your** accounts, but not the accounts of other persons. Some allowlisted APIs accept writes with a bearer token (`api.anthropic.com`, `api.openai.com`, and `storage.googleapis.com` or `github.com` if you enable them). With a token that a prompt injection planted, the agent could use such an API to upload data to the account of an attacker. Put only the hosts that you really use in the allowlist.

### Git on the host

The agent makes commits, branches and worktrees in the box, so most of the `.git` of the repository is writable there. Git on the host trusts what it finds in `.git`. A `.git/commondir` file, or the `.git` file of a worktree, can point at a directory that the agent made. Then git uses the config and hooks of that directory, and a `core.fsmonitor` setting there runs a command on the next `git status`. Editors run `git status` automatically when files change.

`git-guard` closes this path. It is a wrapper, installed as `git` ahead of the real `git`. `run.sh` records each directory that it mounts in `~/.config/agentbox/mounted-repos`. For each directory, it also records the git dir that git can use there. `run.sh` calculates this git dir from the paths before the session starts. It is the own `.git` of the repository, the main `.git` of a mounted worktree or subdirectory, or none for a directory that was not a repository. Before git runs in a recorded directory, git-guard checks that

- git will use exactly that git dir for config and hooks (read-only in the box), or the directory of a submodule under its `modules/` (also read-only); if `run.sh` recorded no git dir, any repository is from the agent, and git-guard refuses it;
- that git dir has no `commondir` file;
- the git dir of a worktree is `<git dir>/worktrees/<name>`;
- if `extensions.worktreeConfig` is on (sparse-checkout turns it on), the `config.worktree` files hold only sparse-checkout settings (the agent can write these files);
- `git rebase --continue` finds no `exec` lines in a rebase that the agent left half done.

If a check fails, git stops with an explanation. git-guard passes other repositories directly to git. The check costs one `git rev-parse`, which reads the config but runs nothing from it. `tests/run.sh` reproduces the attacks with real git. It checks that the attacks work on plain git and fail on git-guard.

`install.sh` installs git-guard as a **copy** when you answer `y` (or with `--git-guard`). git-guard runs on each git call, so it must not be a link into a clone that a session can write. `install.sh` never replaces a `~/.local/bin/git` of your own. To install git-guard by hand from a clone:

```bash
mkdir -p ~/.local/bin
install -m 755 git-guard ~/.local/bin/git
```

`~/.local/bin` must be first in `PATH`, for your shells and for programs that start from the desktop (editors). On systemd desktops (Fedora, Ubuntu, ...), the file `~/.config/environment.d/agentbox.conf` sets this. It applies at the next login.

agentbox writes this file when it installs git-guard. If git-guard is there and the file is not, an installed agentbox writes the file at its next start. It writes the file only once per installation: if you do not want the file, delete it, and it does not come back. agentbox never changes a file or link that is already there. `agentbox uninstall` removes the file only if its content is still the same as agentbox wrote it. The content of the file:

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

If you set your own `GIT_CONFIG_COUNT` entries for the session, merge them into one file. The `environment.d` file that is read last sets the count, and the entries of the other file are lost.

To check, run `command -v git` in a terminal and in the terminal of your editor. It must print `~/.local/bin/git`. Some editors have a setting for the git executable (VS Code `git.path`, JetBrains "Path to Git executable"). In these editors, you can set it to `~/.local/bin/git` explicitly. While `git` is not git-guard, `run.sh` shows a warning at each start.

An installed agentbox updates the copy at each `agentbox update` and `rollback`. If you run agentbox from a clone, update the copy yourself: run `install -m 755 git-guard ~/.local/bin/git` from the copy that you run.

git-guard does not cover these risks, because the agent writes the files that git on the host then uses:

- **Hooks that run files from the work tree.** The config of your repository can point `core.hooksPath` into the work tree (husky: `.husky/_`). Or a hook can run tools that files in the work tree configure (the pre-commit framework reads `.pre-commit-config.yaml`). Then the agent can change what runs on your next `git commit` on the host. Before you commit there, review the diff of such files, or commit from the box.
- **A rebase the agent left half done.** git-guard looks for `exec` lines only on `git rebase --continue`. `--skip` or an abbreviation (`--cont`) runs them without a check. Before you continue a rebase that you did not start, examine `.git/rebase-merge/git-rebase-todo`, or run `git rebase --abort`.
- **Directories that are not repositories of yours.** If you mount `~/.local`, `~/.cache` or similar directories, the agent can change git-guard itself or the files that agentbox generates. `run.sh` refuses only the code, `~/.config/agentbox` and their parent directories. Mount repositories.
- git-guard does not check a program that calls `/usr/bin/git` directly. But the `environment.d` setting above keeps `core.fsmonitor` off for that program too.
- You cannot update submodules in the box, because `.git/modules` is read-only there.

### Egress

Apart from the remote servers of the MCP modules, the hosts that the agent can reach are in groups:

| Where | What |
|---|---|
| `egress.d/<name>.conf` | Shared groups, in git |
| `egress.local.d/<name>.conf` | Your own, in [your files](#your-files). A name that also exists in `egress.d/` replaces that group |

`AB_EGRESS` in `config.env` lists the enabled groups. If it is not set, its value is `anthropic openai pypi go`. A list replaces this default fully, and `AB_EGRESS=` (empty) enables no groups.

Claude Code does not start without `anthropic`. pi needs `openai` only with a ChatGPT subscription (with an API key, pi goes through its sidecar). Thus, if you use only pi with a key, you can omit both groups. At each start, `run.sh` writes the hosts of the enabled groups and of the enabled MCP modules into a file that `squid.conf` includes. If this file changed, `run.sh` recreates squid. Open sessions lose egress for a short time.

| Group | Hosts | For |
|---|---|---|
| `anthropic` | `api.anthropic.com`, `platform.claude.com`, `claude.ai` | Claude Code, required by it |
| `pypi` | `pypi.org`, `files.pythonhosted.org` | pip / uv packages (see [Python](#python)) |
| `go` | `proxy.golang.org`, `sum.golang.org` | Go modules (see [Go](#go)) |
| `openai` | `auth.openai.com`, `api.openai.com` | pi with a ChatGPT subscription (see [pi](#pi-openai)) |
| `github-read` | `github.com` and its content hosts | anonymous read access to public GitHub (see [GitHub read access](#github-read-access-optional)) |
| `gcs` | `storage.googleapis.com` | Google Cloud Storage, all buckets |

A group file is data, and agentbox never runs it. Put one host on each line. `#` starts a comment.

```
# egress.local.d/test-data.conf
test-data.s3.eu-central-1.amazonaws.com   # HTTPS (port 443) and plain HTTP (port 80) to this host
.test.example                             # test.example and all its subdomains
minio.test.example:9000                   # this host on this port only, HTTPS or plain HTTP
```

```
AB_EGRESS=anthropic openai pypi go test-data
```

- Use exact hosts, not domains, where possible. `.amazonaws.com` is all of AWS. Each API that accepts uploads with a token is an exfiltration path (see [Security model](#security-model)), because the agent can use a token that a prompt injection planted. An S3 bucket host is narrower than the regional endpoint.
- Put the credentials for these services in a [per-project environment](#per-project-environment) file. The agent can see them. Use test credentials with the least rights, read-only where possible.
- Squid sees only host names. Thus, squid allows all paths and all methods to an allowed host, on port 443 (HTTPS) and port 80 (plain HTTP). For other ports, use `host:port` entries.
- The list is the same for all sessions, because all sessions share squid.
- Only HTTP(S) goes through squid. Databases and queues are [local services](#local-services) or [test servers](#test-servers).

## Agents

### pi (OpenAI)

[pi](https://pi.dev) runs in the same box as Claude Code: same image, networks, squid, MCP sidecars, repo protections, Python and Go. Start it with `agentbox pi` instead of `agentbox`. Arguments work the same way.

> Do not use the Claude subscription token with pi. Anthropic permits subscription OAuth only in Claude Code and Claude.ai, not in third-party tools.

There are two ways to give pi access to OpenAI models. Both use the **OpenAI** provider of pi (`openai/...` models). `run.sh` selects the mode: it checks if the `openai_api_key` secret exists.

| | ChatGPT subscription (default) | OpenAI API key |
|---|---|---|
| Sign-in | `/login` → OpenAI → *Sign in with ChatGPT*, once | `openai_api_key` Podman secret |
| Billing | Your ChatGPT plan | Per token, OpenAI platform |
| Credential in the agent container | **Yes**: `~/.pi/agent/auth.json` in `ab-pi-home`, including the refresh token. Claude Code sessions cannot see it | **No**: only in the `ab-llm-openai` sidecar |
| Egress | `auth.openai.com`, `api.openai.com` through squid | none, through the sidecar |
| `pi/models.json` | one without overrides (`{ "providers": {} }`) | points the provider at the sidecar |

**Do not use "OpenAI Codex (legacy)".** It is the older ChatGPT integration of pi, and pi marks it as legacy. It connects to the internal Codex backend of ChatGPT (`chatgpt.com/backend-api`), which is not a public API and can change without notice. *Sign in with ChatGPT* on the OpenAI provider gets a token for the public API (`api.openai.com`). It uses the same endpoint and request format as API-key access. To see the models that your plan gives there, use `/model`.

#### Setup: ChatGPT subscription

1. Start pi in a repo: `cd ~/src/myrepo && agentbox pi`. The first run installs pi into the `ab-pi-tools` volume.
2. Run `/login`. Select **OpenAI**, then **Sign in with ChatGPT**. Open the URL that pi shows in your browser on the host, and approve.
3. The browser then goes to `http://127.0.0.1:1455/auth/callback?...` and shows a connection error. This is expected: the callback listener runs in the container, not on your host. **Copy the full URL from the address bar.** Paste it into the prompt of pi.
4. pi keeps the tokens in `~/.pi/agent/auth.json` in `ab-pi-home` and refreshes them automatically. You must do this sign-in once per box, not once per repo.
5. Select an `openai/...` model with `/model`. To make it the default, press `Ctrl+S`.
6. Check MCP with `/mcp`: it lists `context7` and the modules in `AB_MCP`.

**The agent can read the token**, as Claude Code can read the Claude OAuth token. pi must write and refresh the token, so it cannot be in a sidecar. To revoke the token, run `/logout` in pi. Then end the session in the security settings of your ChatGPT account.

`auth.openai.com` and `api.openai.com` come from the `openai` [egress group](#egress), which is enabled by default. All sessions share squid, so Claude Code sessions can also reach these hosts. If you use pi with an API key or do not use pi, remove `openai` from `AB_EGRESS`. The legacy provider also needs `chatgpt.com`. To allow it, add it to a group of your own in `egress.local.d/`.

#### Setup: OpenAI API key

`pi/models.json` points the built-in `openai` provider of pi at the `ab-llm-openai` sidecar. The sidecar replaces a caller token with the real key and forwards the requests to `api.openai.com` with certificate verification. The key never goes into the agent container.

1. Create a project API key with a spending limit in the OpenAI platform.
2. Store the key (one command at a time):
   ```bash
   read -rsp 'OpenAI API key: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create openai_api_key -; echo; unset T
   ```
3. Run `agentbox pi`. It creates `llm_openai_caller` and starts the sidecar. Select an `openai/...` model with `/model`. You do not need `/login`.

#### What pi gets from the host, read-only

| Host file | In the container | Purpose |
|---|---|---|
| `pi/models.json` | `~/.pi/agent/models.json` | OpenAI API endpoint = the sidecar (API-key mode); with a subscription, a `models.json` without overrides (`{ "providers": {} }`) |
| generated by `run.sh` | `~/.pi/agent/mcp.json` | MCP servers of the enabled modules, with caller tokens from the environment |
| `skills/` | `~/.pi/agent/skills` | Same personal skills as Claude Code |
| `AGENTS.md` | `~/.pi/agent/AGENTS.md` | Same personal instructions as Claude Code; an empty file if there is no `AGENTS.md`. See [Memory and personal instructions](#memory-and-personal-instructions) |
| `pi-extensions/` in [your files](#your-files) | `~/.pi/agent/extensions` | Extensions that you allow (empty by default) |

Read-only is important here. pi runs the extensions that it finds in its agent directory. pi also reads its model endpoint and MCP servers from these files. If the agent could write these files, it could redirect its own model traffic, add servers or plant code that stays across sessions. Sessions, `settings.json` and `auth.json` stay writable in `ab-pi-home`.

pi runs with `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1` and `PI_TELEMETRY=0`: pi does not refresh the model catalog, check the version or send telemetry.

#### Extensions and skills

MCP support is built into pi, so you do not need an extension. `pi install ...` does not work in the box (no npm access), and it would also write to the agent directory. To allow an extension, read it. Then copy it into `~/.config/agentbox/pi-extensions/` on the host. Skills come from `skills/`, the same directory that Claude Code uses, so `sync-skills.sh` covers both agents. Some skills for Claude Code use Claude-specific features such as subagents, and these skills can work less well in pi.

### Memory and personal instructions

The auto memory of Claude Code is **off by default** in the box. `run.sh` sets `autoMemoryEnabled: false` in `~/.claude/settings.json` only when that key is not set yet, so it keeps an explicit choice there. To use auto memory in one project, set `"autoMemoryEnabled": true` in the `.claude/settings.json` of that repo.

Put the instructions for all repos in `~/.config/agentbox/AGENTS.md`. Start from the template. It has the rules that this box needs (ask before you commit, where to find library documentation):

```bash
cp agents/AGENTS.md.example ~/.config/agentbox/AGENTS.md
```

Both agents get the same file, **read-only**. Claude Code gets it as `~/.claude/CLAUDE.md`, and pi gets it as `~/.pi/agent/AGENTS.md` (its global context file). The reason for read-only is the same as for personal skills (see [Skills](#skills)). If the agent wrote this file in its home volume, the file would go into every future session.

If there is no `AGENTS.md`, the agents get an empty file at these paths. These paths are always mounted for this reason: if a file is mounted only sometimes, it leaves an empty placeholder in the volume, owned by root. A session without the mount would read this placeholder and fail. Thus, Claude Code does not see a `CLAUDE.md` that its `/memory` or `#` notes wrote into its volume. While such a file is there, agentbox shows a warning at each start, with the commands to read and remove the file.

Keep the text agent-neutral. Name an agent only where a rule is specific to that agent. Changes apply at the next session start. This is also true when you edit the file from a session: the running session keeps the version that it started with.

### Status line

`claude/statusline.py` draws the status line of Claude Code. It shows the model, the repo directory and git branch, the context window use, the 5-hour and weekly subscription limits with their reset times, and the session cost. Percentages become yellow at 50% and red at 80%. If Claude Code does not send the data for a part (limits with an API key, context before the first reply), the status line does not show that part.

At each start, `run.sh` makes a copy of the script in `~/.cache/agentbox/session/claude/`, because the files of an installed version cannot be relabelled for SELinux. This copy is mounted read-only as `~/.claude/statusline.py`. Edit `claude/statusline.py` in a clone, not the copy. `run.sh` adds the `statusLine` setting to `~/.claude/settings.json` only when that key is not there, so your own status line there stays and replaces this one. To use this status line instead, delete the key and start a new session. Times use the time zone of the host: `run.sh` gives it to the session as `TZ`.

**About `--dangerously-skip-permissions`.** In this box, it is a reasonable choice. The worst case is changed files in the repo (you can recover them with git), read access to Grafana and Graylog within Viewer rights, and requests to allowlisted hosts. It is reasonable only if the service accounts are really read-only.

### Skills

Claude Code loads skills from two locations. Both work in the box without network access:

| Kind | Location | How it gets into the box |
|---|---|---|
| Project skills | `<repo>/.claude/skills/<name>/SKILL.md` | Nothing to do: the repo is mounted |
| Personal skills | `~/.claude/skills/<name>/SKILL.md` | Put them in `~/.config/agentbox/skills/`. This directory is mounted **read-only** over `~/.claude/skills` |

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

To keep skills in a different location, set `AB_SKILLS_DIR=/path/to/skills`. Changes apply at the next session start, and you do not need to restart the sidecars. To check, run `/skills` in a session.

**Why read-only.** `~/.claude` is in the writable `ab-claude-home` volume. If the agent wrote skills there, they would silently stay in every future session and every repo. Thus, they are a convenient place where a prompt injection can survive. With the read-only mount, only you can change personal skills, from the host. Project skills are part of the repo, and they go through your normal diff review.

Scripts that come with a skill run in the box, with the same network and credential restrictions as everything else.

**Plugins and marketplaces** (`/plugin install ...`) and `npx skills add` do not work in the box. They download from `github.com` and `registry.npmjs.org`, and these hosts are blocked. Use a skill source (below). `run.sh` installs skill sources on the host.

#### Skill sources: `AB_SKILLS`

A skill source is a git repository of skills, described in a small file:

| Directory | |
|---|---|
| `skills.d/<name>.conf` | Shared sources, in git: `mattpocock` |
| `skills.local.d/<name>.conf` | Your own, in [your files](#your-files). A name that also exists in `skills.d/` replaces that source |

`AB_SKILLS` in `config.env` lists the enabled sources (`AB_SKILLS=mattpocock`). Nobody gets skills that they did not enable. The `.conf` file is `KEY=VALUE` data, and agentbox never runs it. Each repository can be only one source. If two sources have the same `URL`, the start stops with an error. In that case, list the skills of both sources in one `ONLY`.

| Key | |
|---|---|
| `URL` | Required. Git URL of the repository |
| `ONLY` | Comma-separated skills to install, as the repository names them. Default: all |
| `PREFIX` | Prefix for the installed names. Default: the repository owner; `PREFIX=` (empty) for none |
| `REF` | Branch, tag or commit to pin to. Default: the default branch, with updates that the [update check](#update-check) offers |

At each start, `run.sh` compares each enabled source with the installed skills. If they are different, `run.sh` syncs on the host: it installs a new source, syncs again a source whose `.conf` changed, and removes the skills of a source that you removed from `AB_SKILLS`. It syncs a changed source at the installed commit, so a changed `ONLY` does not also upgrade it. If nothing changed, there is no network access. If a sync fails, `run.sh` shows a warning, and the session starts with the installed skills.

Read the skills that you enable. Skills are instructions that the agent obeys, and their bundled scripts run in the box. Before you accept an update, read the compare link that the update check shows. Put the skills of a team into a repository of their own and a source in `skills.d/`, the same as the skills of other authors.

##### How a source is installed: `sync-skills.sh`

`run.sh` calls `sync-skills.sh`, and you can also run it by hand for a one-off repository. It makes a new clone of the repository in a temporary directory. It does not keep the clone: the clone would be in a location that a session which mounts agentbox can write, and a hook planted in it would run on the host. It finds each directory with a `SKILL.md` at any depth. It copies each of these directories **flat** into `skills/<name>/`, because Claude Code looks only one level deep.

It records in `skills/.sources/<owner>__<repo>` what it installed, from where and at which commit. It removes skills that the upstream repository dropped or that you deselected. It never overwrites a skill that it did not install. It does not install a skill that contains symlinks: the link could point at a file on your host, and that file would then be in the skills of the agent.

Installed skills get a prefix, by default the repo owner: `code-review` from `mattpocock/skills` becomes `mattpocock-code-review`. Without the prefix, a vendored skill hides a Claude Code built-in with the same name (`/code-review`), and skills from two repos can collide. The script renames the directory and the frontmatter `name`. It also adds a note after the frontmatter of each `SKILL.md`. The text still says `/tdd` or `call the Skill tool with "code-review"`, and the note tells the agent to use `mattpocock-<name>` for the listed skills. The script does not change the text itself.

```bash
./sync-skills.sh <git-url> [ref]               # ref: branch, tag or commit; default: remote default branch
SKILLS_ONLY=a,b,c ./sync-skills.sh <git-url>    # install a subset; upstream names, without the prefix
SKILLS_PREFIX=mp ./sync-skills.sh <git-url>     # another prefix; SKILLS_PREFIX= (empty) installs names unchanged
./sync-skills.sh --remove <git-url>             # remove what it installed from there
```

`run.sh` does not manage skills that you synced by hand: it does not change or remove them. Older versions kept clones and records in `vendor/`. At its next start, `run.sh` moves the records to `skills/.sources/`. agentbox no longer uses the clones (`vendor/<owner>__<repo>/`), and you can delete them.

##### Example: mattpocock/skills

`skills.d/mattpocock.conf` installs engineering and productivity skills from the repository, but not the unfinished `in-progress` skills. To enable it, set `AB_SKILLS=mattpocock`.

Then run `/mattpocock-setup-matt-pocock-skills` in a session, once per repo. Important points for this box:

- **Issue tracker.** The GitHub option tells the agent to use the `gh` CLI, but the box does not have it. During setup, select **local markdown** or GitHub. If you select GitHub, edit the generated issue-tracker document in your repo after the setup. Make it say "use the github MCP tools" instead of `gh` commands (this needs [GitHub (MCP)](#github-mcp)). The other skills read that document, so the change applies everywhere.
- **`mattpocock-pr`** creates pull requests. It needs GitHub MCP. Before you use it, push the branch from the host.
## Integrations

### MCP servers

Each MCP server is a module: a directory with an `mcp.sh` file and the other files that the server needs (for example, an nginx template).

| Directory | |
|---|---|
| `mcp/<name>/` | Shared modules, in git: `context7`, `grafana`, `graylog`, `github`, `woodpecker`, `tabularis`, `dbhub`, `bb4` |
| `mcp.local/<name>/` | Your own modules, in [your files](#your-files). If a module has the same name as a module in `mcp/`, it replaces that module |

`AB_MCP` in `config.env` lists the enabled modules (`AB_MCP=grafana graylog`). The `context7` module is always enabled. At each start, `run.sh` checks the settings and secrets of the enabled modules and starts their sidecars. It writes one MCP config for both agents (Claude Code: `--mcp-config`, pi: `~/.pi/agent/mcp.json`). It also writes the remote hosts for squid (see [Egress](#egress)).

A module can lack a setting or a secret, can be absent from this version, or can fail to start. Such a module is left out of that session with a warning that gives the reason (see [Daily usage](#daily-usage) for how agentbox shows warnings again). The other modules work. If the start of the module failed, what the module already runs stays for the sessions that use it. If a setting or a secret is gone, agentbox removes what the module runs, as for a module that you removed from `AB_MCP`. Nobody gets servers that they did not enable, and a new module does not change `run.sh`.

#### Writing a module

`mcp.sh` is a bash script that `run.sh` sources on the host. It sets variables. If the server needs a sidecar, it also defines `mcp_start`. The code outside `mcp_start` runs without `set -e`: if a command there fails, the start does not stop. Put checks in `mcp_start`, which can exit with `$MCP_TAKE_AWAY`. Or, if a value is not correct, leave the URL empty:

| | |
|---|---|
| `MCP_URL` | Required if `MCP_SERVERS` is not set. The URL that the agents connect to: `http://ab-mcp-<name>:<port>/mcp` for a sidecar. For a remote server, the URL of the server (and put its host in `MCP_EGRESS`) |
| `MCP_SERVERS=(...)` | Optional, for a module with more than one server (see `mcp/bb4/`). Each item is `"<name>\|<url>\|<caller or ->\|<description>"`. The items replace the one server that has the name of the module. `caller`: the agents send the caller token of the module to the server. `-`: the agents send no token (a remote server). `caller` needs `MCP_CALLER_SECRET`. Each server name must be different from the other server names in the module and in other modules. If a module does not obey a rule, the start leaves it out and gives the reason. As for `MCP_URL`, the agents reach a host without a dot without the proxy, unless the host is in `MCP_EGRESS` |
| `MCP_DESCRIPTION` | One line that pi shows |
| `MCP_CONFIG=(...)` | The `config.env` keys that the module reads. `run.sh` accepts them only while the module is enabled |
| `MCP_REQUIRED_CONFIG=(...)` | The keys from `MCP_CONFIG` that must have a value |
| `MCP_SECRETS=(...)` | Podman secrets that must exist, for example the API token of the service |
| `MCP_SECRET_HELP=(...)` | Optional: `"<secret>: what to type"` for each secret. `agentbox setup` shows it when it asks for the secret |
| `mcp_secret_value()` | Optional: `<secret> <what was typed>` → the value to store. Use it for a secret that agentbox does not store as typed (`graylog` stores `base64("<token>:token")`) |
| `MCP_OWN_SECRETS=(...)` | Podman secrets that `mcp_start` creates itself. `agentbox uninstall --all` removes them |
| `MCP_CALLER_SECRET` | The name of a caller token secret. agentbox generates the token on first use. The agents send `Authorization: Bearer <token>`, and the sidecar checks it. In the session, the environment variable `AB_MCP_TOKEN_<NAME>` holds the token |
| `MCP_EGRESS=(...)` | Hosts that the agent itself connects to (remote servers). agentbox adds them to squid's allowlist |
| `MCP_IMAGES=(...)` | Images that `AB_UPGRADE` pulls |
| `mcp_start()` | Starts the sidecars with `start_sidecar <container> <podman run arguments>`. Name them `ab-mcp-<module>` or `ab-mcp-<module>-<part>`. `run.sh` removes containers with that prefix that no enabled module started. (If the start of a module failed, the module keeps its own containers.) The function runs in a subshell. On an error, give the reason with `ab_error "..."` and run `exit 1`. agentbox prints the reason and shows it in the warning. agentbox then leaves out only that module, and keeps what the module already runs for open sessions. If the access must stop, run `exit "$MCP_TAKE_AWAY"`: agentbox then also removes the sidecars of the module and their copies. agentbox marks what a module starts as its own (label `agentbox.module`; for a host service, its description). agentbox finds these items by that mark, not by the name. Variables that the function sets do not reach the rest of `run.sh`. `$MCP_DIR` is the directory of the module, and `$IMG_NGINX` is the nginx image that the shipped modules use. Mount the files of the module as `-v "$(sidecar_copy <container> "$MCP_DIR/<file>"):<path>:ro,Z"`, never directly (see [Troubleshooting](#troubleshooting), files that cannot be read). If a program must run on the host, start it with `start_host_unit agentbox-mcp-<something> [VAR=value...] -- <command...>`. This makes a transient systemd user service. agentbox restarts the service when its command changes, and stops it when no enabled module asks for it (see `mcp/tabularis/`) |

A remote server needs three lines, as in `mcp/context7/mcp.sh`:

```bash
MCP_DESCRIPTION="Issue tracker"
MCP_URL="https://mcp.example.com/mcp"
MCP_EGRESS=(mcp.example.com)
```

If a server needs a credential, give it a sidecar that holds the credential. Then the token never enters the agent container. See `mcp/graylog/` (nginx adds the header) and `mcp/grafana/` (the server checks a caller token). Attach sidecars to `ab-internal` (the agent reaches them by name) and to `ab-egress` (their way out).

**A module is code that runs on your host** with your user, like `run.sh` itself. Read a module before you enable it. Treat a `mcp.local/` module from another person like a script from that person.

### GitHub (MCP)

Optional: the `github` module (`AB_MCP=... github`). With it, `run.sh` starts two more sidecars, and the agent gets GitHub through MCP. The agent can use pull requests, issues, review comments, CI runs and logs, and it can read repository contents. **The token never enters the agent container**, and `github.com` stays out of the egress allowlist.

What the agent can **not** do: `git fetch`/`git push`, or change code on GitHub. Code goes through you:

1. the agent commits locally in the mounted repo;
2. you review the diff and `git push` from the host;
3. the agent opens the PR, and reads CI results and review comments through MCP.

#### How it is wired

- **`ab-mcp-github-srv`** runs the official `github-mcp-server` in HTTP mode. It holds no token. It is attached only to `ab-egress`, so the agent cannot reach it directly.
- **`ab-mcp-github`** (nginx, `mcp/github/nginx.conf.template`) is the only entry point. It
  - rejects requests without the caller token (`github_mcp_caller`, which agentbox generates);
  - replaces the caller token with the PAT;
  - always sets `X-MCP-Toolsets` to `GH_TOOLSETS` and `X-MCP-Lockdown: true`, and removes any `X-MCP-Readonly`, `X-MCP-Tools` or `X-MCP-Insiders` that the client sends;
  - always proxies to the server root, so the agent cannot use other server paths.

The agent can add its own MCP registrations in `ab-claude-home`. Thus nginx, not the client config, enforces the server behaviour. **The real boundary is still the PAT's permissions.**

Default toolsets: `context,repos,issues,pull_requests,actions`. To change them, set `GH_TOOLSETS` in `config.env`. The next start recreates the sidecar.

Lockdown mode hides content in public repositories from users without push access to them. At this time, it applies only when the agent reads issues. Thus content that other tools get from public repositories can still carry prompt injection.

#### 1. Create a fine-grained personal access token

GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.

- **Resource owner:** your organization (the organization can require approval).
- **Repository access:** *Only select repositories*, and only the repositories that the agent works on.
- **Expiration:** short, for example 30 to 90 days.
- **Repository permissions:**

| Permission | Access | Why |
|---|---|---|
| Metadata | Read | Required by GitHub |
| Contents | **Read** | Read files, branches, commits. No writes: code changes go through your `git push` |
| Pull requests | Read and write | Open PRs, read and post review comments |
| Issues | Read and write | Read and comment on issues (remove if you do not need it) |
| Actions | Read | CI runs and logs |
| Workflows | **No access** | |

Set all other permissions to *No access*. With Contents set to Read, the agent cannot create branches, commit files or change workflows on GitHub, whatever tools the server makes available.

If the agent can create a branch or a commit on GitHub, the token has Contents write, or it is a classic token. Then the agent bypasses your local git, its hooks and your commit signing. Check under Settings → Developer settings → Personal access tokens. A classic token (scope `repo`) can write to every repository that you can write to, and you cannot limit it to reading code. Replace it with a fine-grained token.

Also protect `main` with a branch ruleset that requires a pull request, so that merges always need your approval.

#### 2. Store the token and enable the module

```bash
read -rsp 'GitHub token: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create github_pat -; echo; unset T
```

Add `github` to `AB_MCP` in `config.env`. The next start creates `github_mcp_caller` and the sidecars. To check, use `/mcp` in a session.

#### Disable

Remove `github` from `AB_MCP`, then:

```bash
podman rm -f ab-mcp-github ab-mcp-github-srv
podman secret rm github_pat github_mcp_caller
```

#### GitHub read access (optional)

The GitHub MCP sidecar gives access to your own repositories. For **anonymous read access to public GitHub** (to clone a library and read its source, to get `uv` dependencies from git, raw files, release downloads), add `github-read` to `AB_EGRESS`. The next start recreates squid.

What it changes and what it does not change:

- **No writes.** There is no GitHub token in the agent container, so the agent cannot push, open issues, comment or create gists. Also, the agent cannot reach your private repositories this way.
- **It cannot be limited to reads at the network level.** Squid sees only the host name of a `CONNECT`, not the HTTP method or path. Thus it allows all requests to these hosts. Without credentials, this is harmless for GitHub itself. But each allowed host is still a place to which the agent can send requests.
- **The main risk is inbound.** Public repositories, issues and READMEs are arbitrary third-party text and code. They are a prompt injection source and a supply-chain source, like PyPI. Compare this risk with what the agent can read in the box: your code, and all data that the MCP servers return, such as logs.

A more contained alternative: leave it off, and tell the agent to read public repositories through the GitHub MCP tools (the PAT can read public repositories).

### Woodpecker (MCP)

Optional: the `woodpecker` module (`AB_MCP=... woodpecker`). The agent reads [Woodpecker CI](https://woodpecker-ci.org/): repositories, pipelines and their status, step logs, pipeline configs, and the queue. **Read only**: the agent cannot start, restart, cancel or approve anything.

Woodpecker has no official MCP server. The module runs [`rtuszik/woodpecker-mcp`](https://github.com/rtuszik/woodpecker-mcp). `mcp/woodpecker/mcp.sh` pins it to one release, and agentbox scans it daily with the other images.

#### How it is wired

Woodpecker's personal access tokens have no scopes: a token can do all that its user can do. For example, it can start pipelines that get the secrets of the CI. Thus the token never reaches the MCP server, and a layer below the server refuses writes:

- **`ab-mcp-woodpecker-srv`** runs woodpecker-mcp without its write tools (`WOODPECKER_MCP_READ_ONLY`). It is only on the `--internal` network `ab-mcp-woodpecker`, and it has no DNS for outside names. It sees nginx and nothing else, not even squid on `ab-internal`, and the agent cannot reach it. For this server, "Woodpecker" is port 8081 of nginx. The token that the server sends there is a bridge key, not the Woodpecker token.
- **`ab-mcp-woodpecker`** (nginx, `mcp/woodpecker/nginx.conf.template`):
  - on `:8080`, for the agent: checks the caller token (`woodpecker_mcp_caller`) and sends the bridge key (`woodpecker_bridge_key`, generated) to the server;
  - on `:8081`, for the server: checks the bridge key and lets **GET and HEAD only** through. It adds the Woodpecker token and verifies the certificate of Woodpecker. Whatever the server code does, only reads reach Woodpecker.

#### Setup

1. In Woodpecker, log in as a user for the agent. This user must be able to read only the repositories that the agent needs. Woodpecker takes permissions from your forge (Gitea, GitHub, GitLab, ...), so read access there is sufficient. Your own user also works, with all your rights behind the token, but the GET-only proxy still limits it to reads.
2. Under the settings of your user, copy the personal access token.
3. `agentbox setup`: enable `woodpecker`, and enter `WOODPECKER_URL` (for example `https://ci.example.internal`) and the token. agentbox stores the token as the Podman secret `woodpecker_token`. To do it by hand, set `WOODPECKER_URL=...` in `config.env`, add `woodpecker` to `AB_MCP`, and run `read -rsp 'Woodpecker token: ' T && printf '%s' "$T" | podman secret create woodpecker_token -; echo; unset T`.
4. If Woodpecker uses https with a certificate from your own CA, set `WOODPECKER_CA` to the CA certificate file on the host.

#### Things to watch

- **Step logs are third-party text.** Woodpecker masks the values of its secrets in logs. But all other text that a step prints reaches the agent, and it can carry prompt injection like any other content.
- If `/mcp` shows that the server fails with 401 from Woodpecker, the token is wrong or expired. To replace it, use `e <number>` in `agentbox setup`.

#### Disable

Remove `woodpecker` from `AB_MCP`. The next start removes the sidecars. The secrets stay until you remove them (or until `agentbox uninstall --all` removes them): `podman secret rm woodpecker_token woodpecker_bridge_key woodpecker_mcp_caller`.

### Tabularis (MCP)

Optional: the `tabularis` module (`AB_MCP=... tabularis`). [Tabularis](https://tabularis.dev) is a desktop database client with a built-in MCP server. With the module, the agent sees the connections that you saved in Tabularis. Through them, it can list tables, read schemas and run SQL. **Database passwords stay on the host**, in Tabularis and your system keychain. The agent container gets neither the passwords nor a route to the databases.

#### How it is wired

Tabularis's MCP server (`tabularis --mcp`) speaks only stdio. It needs what the app has on the host: the saved connections, the keychain, and the open app window where you approve writes. Thus it runs on the host, and a chain of three parts connects it to the box:

- **`agentbox-mcp-tabularis`** is a transient systemd user service that agentbox starts and restarts automatically (`systemd-run --user`; no unit file; it stops when you log out). It runs [supergateway](https://github.com/supercorp-ai/supergateway), which agentbox installs from `mcp/tabularis/bridge/package-lock.json` (see below). supergateway
  - listens only on `127.0.0.1:TABULARIS_PORT`, never on the network;
  - requires the bridge key (`tabularis_bridge_key`, generated; its file is `~/.cache/agentbox/tabularis/bridge.key`, mode 600), so other users on the host cannot use it while it runs;
  - starts one `tabularis --mcp` for each MCP session (`--stateful`). Tabularis handles one request at a time, so a write that waits for approval in one session does not block the other sessions.
- **`ab-mcp-tabularis-relay`** is socat on the host network. It holds a unix socket in the volume `ab-mcp-tabularis-sock` and forwards it to `127.0.0.1:TABULARIS_PORT`. A container holds the socket because SELinux does not let containers connect to a socket that a host process holds. It has no secrets, and the agent cannot reach it.
- **`ab-mcp-tabularis`** (nginx, `mcp/tabularis/nginx.conf.template`) is only on `ab-internal`. It rejects requests without the caller token (`tabularis_mcp_caller`), replaces that token with the bridge key, and forwards the requests to the socket.

Tabularis writes each query and its result to stderr. The module sends that output to `/dev/null` and runs supergateway with `--logLevel none`. Thus no data from your databases goes into the journal.

#### Setup

1. Install Tabularis on the host and save your connections in it. The command `tabularis` must be in `PATH`. If it is not, set `TABULARIS_CMD` in `config.env`, for example `TABULARIS_CMD=flatpak run <app id>` (agentbox adds `--mcp`).
2. Install Node.js (`node` and `npm`) on the host. The first start uses it to install supergateway, and this needs the npm registry one time. `ss` (iproute2) must also be on the host, as it is on Fedora. agentbox uses it to make sure that the program on `TABULARIS_PORT` is its bridge.
3. In Tabularis, under Settings → MCP, select what the agent can do:
   - **Read-only mode**, for each connection (off by default). Use it for each connection that the agent must only read: Tabularis then refuses all statements other than `SELECT` on that connection.
   - **Approval mode**: by default, each write waits until you approve it in the Tabularis window (after 120 s, it is refused). If Tabularis does not run (quit, not only its window closed), writes are refused immediately. The stricter setting is to approve each query, reads included. If you turn approvals off, only read-only mode stays between the agent and your data.
4. Add `tabularis` to `AB_MCP`. The next start creates the secrets, starts the service and the two sidecars, and waits until supergateway listens. To check, use `/mcp` in a session.

If the agent must write, let Tabularis run while you work: approvals need the app.

#### Things to watch

- **This is your access to your databases.** Isolation does not limit what Tabularis does with a query that it accepts. Read-only mode and approvals in Tabularis are the boundary. Thus set them before you enable the module, and leave out connections that the agent does not need.
- **Query results are third-party text.** Data from a database can carry prompt injection like any other content.
- **A program of agentbox runs on your host.** supergateway comes from npm and runs with your user, like `run.sh`. `mcp/tabularis/bridge/package-lock.json` pins the version of supergateway and of each package below it, with its hash. The module installs exactly that tree with `npm ci --ignore-scripts` into `~/.cache/agentbox/tabularis/bridge-<hash of package.json and the lock file>`. npm refuses a package if its content does not match the hash, and no install scripts of packages run.

  If a new agentbox release has a changed lock file, the next start installs the new tree. agentbox removes trees that no start used for 30 days. If `npm ci` fails (for example, no registry), the session starts without the module and gives the reason. `package.json` also overrides the MCP SDK packages that supergateway pins (`@modelcontextprotocol/sdk`, `server`, `client`, `node`, and `@hono/node-server` under them). The overrides use later releases that fix vulnerabilities. Two of these vulnerabilities affect a server with several sessions at the same time, as the bridge runs, and one is a missing limit on the size of a request.

  A known issue stays: supergateway itself uses zod 3, for which npm lists a way to exhaust memory with an input that is too large (GHSA-mrhx-c7xc-m3w5, fixed only in zod 4). Only requests with the bridge key reach supergateway. Thus, at most, the agent can stop its own bridge. This issue will go away when supergateway moves to zod 4. Maintainers update the lock file with `cd mcp/tabularis/bridge && npm install --package-lock-only --ignore-scripts` after they change a version in `package.json`. They check it with `trivy fs mcp/tabularis/bridge` and review the diff. An override is removed when supergateway itself pins a fixed release.
- **On a host that you share with other users**, the port of the bridge is an ordinary TCP port on `127.0.0.1`. At each start, agentbox makes sure that the bridge holds the port. But while the bridge is down (stopped, failed, or after you log out), another local user could take the port. That user then gets the requests of the agent, with the bridge key. supergateway cannot listen on a unix socket, which would close this gap. If only you use the machine, this risk does not apply.
- `TABULARIS_PORT` (default `47821`) must be free on the host. If another program listens there, agentbox leaves the module out of that start with an error. It does not send the requests of the agent and the bridge key to that program. If `/mcp` shows the server as failed, see `systemctl --user status agentbox-mcp-tabularis`. If the bridge fails three times in one minute (for example, supergateway does not start), it stays down until the next agentbox start. supergateway intentionally logs nothing; to see an error, run it manually with the command shown there, without `--logLevel none`.

#### Disable

Remove `tabularis` from `AB_MCP`. The next start stops the service and removes the sidecars. The secrets, the socket volume and the key file stay until you remove them (or until `agentbox uninstall` removes them):

```bash
podman secret rm tabularis_mcp_caller tabularis_bridge_key
podman volume rm ab-mcp-tabularis-sock
rm -r ~/.cache/agentbox/tabularis
```

### DBHub (MCP)

Optional: the `dbhub` module (`AB_MCP=... dbhub`). The agent reads the SQL databases that you list. It searches schemas, tables, columns and indexes and runs queries, **read only**. [DBHub](https://github.com/bytebase/dbhub) supports PostgreSQL, MySQL, MariaDB, SQL Server, Oracle and SQLite. It has only two tools, so it uses little of the agent's context. Unlike [Tabularis](#tabularis-mcp), it needs nothing on the host, but it has no window to approve writes: it only reads.

#### How it is wired

- **`ab-mcp-dbhub`** runs `bytebase/dbhub` on `ab-internal` and `ab-egress`. `mcp/dbhub/mcp.sh` pins it to one release, and agentbox scans it daily with the other images. It connects to the databases directly, because a database connection is not HTTP and cannot go through squid. It rejects requests without the caller token (`dbhub_mcp_caller`). In addition, a `Host` allowlist protects against DNS rebinding.
- **Your `dbhub.toml`** lists the databases as `[[sources]]`, with their passwords. DBHub does not read this file. A start can come after a change to `dbhub.toml`, to the module or to the agentbox image. At such a start, `mcp/dbhub/config.py` parses the file with Python's TOML parser (in a throwaway container of the agentbox image, without network). It then writes a new DBHub config from the parsed data: your sources, with only strings, numbers, booleans and lists of these as values. For each source, the config also has the two tools that the agent gets: `execute_sql` with `readonly = true`, and `search_objects`.

  If `dbhub.toml` has anything else, the module is left out of that start, with the reason. This includes another table (`[[tools]]` too, because one of your tools could write), a source without an `id`, a nested table or a date. DBHub gets only what agentbox wrote. Thus agentbox and DBHub cannot read your file in two different ways.

  agentbox writes the result to `~/.cache/agentbox/sidecars/ab-mcp-dbhub/dbhub.toml` (mode 600), a copy with the passwords, and mounts it into the sidecar. Next to it is `dbhub.toml.src`, a hash of the data that the copy came from. If that data changes, the next start recreates the copy. If you delete `dbhub.toml` or agentbox refuses it, the start removes the sidecar of the last start and that copy. Thus, if you delete the file, the access stops. The session never sees the passwords.
- **Read-only** in DBHub is two checks. First, DBHub refuses statements that are not reads. Second, on PostgreSQL, MySQL, MariaDB and Oracle, it runs each query in a `READ ONLY` transaction, so the database itself refuses a write that the first check did not find. The real boundary is the database user (see below).

#### Setup

1. For each database, create a user that can read only what the agent needs (PostgreSQL: `CREATE ROLE agent LOGIN PASSWORD '...'`, then `GRANT CONNECT`, `GRANT USAGE ON SCHEMA` and `GRANT SELECT ON ALL TABLES IN SCHEMA`, or `pg_read_all_data` for everything).
2. Write `~/.config/agentbox/dbhub.toml`, with one `[[sources]]` for each database. `id` is the name that the agent uses to select a database. It can have letters, digits, `_` and `-` (DBHub reads `-` as `_`, so `prod-db` and `prod_db` would clash). `description` tells the agent what the database contains:

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

   With `lazy = true`, DBHub connects to that database at the first query. Without it, DBHub connects to all databases when it starts. If one connection fails, DBHub exits, and the agent gets no databases.

   `chmod 600 ~/.config/agentbox/dbhub.toml`: the file holds passwords, and agentbox shows a warning while the group or others can read it. In a DSN, URL-encode special characters in a password (`@` as `%40`). Or use `type`, `host`, `port`, `database`, `user` and `password` instead of `dsn`. [DBHub's TOML reference](https://dbhub.ai/config/toml) describes other source settings (`query_timeout`, `connection_timeout`, `sslmode`, ...).
3. `agentbox setup`: enable `dbhub` (or add it to `AB_MCP`). The next start starts the sidecar. To check, use `/mcp` in a session.

#### Things to watch

- **TLS.** Set `sslmode` in each DSN. `require` encrypts but does not check the certificate of the server. `disable` sends the password and the data as clear text. `verify-ca` and `verify-full` with your own CA need a CA file in the container, and the module does not mount one yet. The module also does not support SSH tunnels (`ssh_*`). The sidecar reaches all that the network of the host reaches.
- **Names in your network.** The sidecar resolves database hosts through Podman's DNS, which uses the resolvers of the host. If a name does not resolve, see the Troubleshooting row "Sidecar can't resolve Grafana/Graylog".
- **Query results are third-party text.** Data from a database can carry prompt injection like any other content.
- If `/mcp` shows `ENOTFOUND ab-mcp-dbhub`, the sidecar exited. Usually, a database refused the connection at start (see `lazy` above). `podman logs ab-mcp-dbhub` shows the database and the reason, such as `no pg_hba.conf entry for host ...`. This means that PostgreSQL's `pg_hba.conf` has no rule for that user from the address of your host, with or without SSL as the DSN requests.

#### Disable

Remove `dbhub` from `AB_MCP`. The next start removes the sidecar and the copy with the passwords in the cache. If you removed the container manually before, the copy stays: `rm -r ~/.cache/agentbox/sidecars/ab-mcp-dbhub`. `dbhub.toml` stays. The caller token also stays until you remove it (or until `agentbox uninstall --all` removes it): `podman secret rm dbhub_mcp_caller`.

### Remote browser (bb4)

Optional: the `bb4` module (`AB_MCP=... bb4`). The agent controls a browser that runs on a browser server, one browser for each user. The browser is not in the box and not on your host, so its windows do not disturb you, and sites see a real browser. The agent gets two MCP servers:

- **`bb4`**, the MCP server of the browser server itself: it starts the browser and configures it (a proxy, a time zone);
- **`bb4-devtools`**, [chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) connected to that browser: it opens pages, reads them, clicks, types and takes screenshots.

**Read this before you enable it.** The browser connects to the internet itself, from that server: **squid's allowlist does not apply to it.** Through the browser, the agent can open any site, fill in any form, and send your code or data anywhere, for example in the address of a page that it opens. The agent decides what to open, and page content can carry prompt injection like any other text that it reads. Thus, while `bb4` is enabled, agentbox shows a warning in capitals at each start, and shows the warning again before the session ([Daily usage](#daily-usage)). Enable it for the work that needs a browser, and disable it again after that work.

#### How it is wired

- **`bb4`** is a remote server, like Context7. The agent connects to `<BB4_URL>/u/<BB4_USER>/mcp` through squid, and squid lets it reach only that host and port.
- **`ab-mcp-bb4-devtools`** runs chrome-devtools-mcp, which speaks only stdio, behind [supergateway](https://github.com/supercorp-ai/supergateway). It uses an image that agentbox builds here from `mcp/bb4/devtools/` (never pulled; scanned daily with the other images). `package-lock.json` pins each package with its hash, and `npm ci --ignore-scripts` installs them. Thus no install script runs, and puppeteer downloads no Chrome.

  The sidecar connects to the DevTools WebSocket of the browser, `ws://<host of BB4_URL>:<BB4_DEVTOOLS_PORT>/u/<BB4_USER>/devtools/browser` (`wss://` for an https `BB4_URL`). It connects directly over `ab-egress`: a WebSocket, not HTTPS through squid. It runs with `--no-usage-statistics` and `--no-performance-crux`, so it sends Google no usage data and no URLs of a performance trace. It logs nothing of the pages. supergateway requires a bridge key (`bb4_bridge_key`, generated), and the agent cannot reach this sidecar.
- **`ab-mcp-bb4`** (nginx, `mcp/bb4/nginx.conf.template`) is on `ab-internal` and on `ab-egress`, where the sidecar is. It checks the caller token (`bb4_mcp_caller`) and forwards requests to the sidecar with the bridge key.

`ab-mcp-bb4-devtools` is on `ab-egress`, which has a way out. Thus chrome-devtools-mcp and the packages below it could connect to any host, not only to the browser server. agentbox accepts this only because the browser that the sidecar controls can reach all hosts anyway, and its packages are pinned and scanned.

The browser server identifies users by the name in the path and has **no authentication of its own**. Anyone who can reach it (only through the VPN) can control the browser of any user, and the agent can too, by name. agentbox cannot add a check there.

#### Setup

1. Connect to the VPN, so that the host resolves and answers. squid and the sidecar resolve it through the DNS of the host.
2. `agentbox setup`: enable `bb4` and enter `BB4_URL` and `BB4_USER`. `BB4_URL` is the base URL of the server, with only scheme, host and port (`http://browser.example.internal:5101`). `BB4_USER` is your user name on the server (your GitHub user name). `BB4_DEVTOOLS_PORT` is the port of the DevTools WebSocket of the browser on the same host (default `5100`). To do it by hand, add the lines to `config.env` and add `bb4` to `AB_MCP`.
3. The first start builds the image `localhost/agentbox-bb4-devtools`. This needs the npm registry one time and takes about a minute. To check, use `/mcp` in a session: `bb4` starts the browser, and then `bb4-devtools` works on its pages.

If `BB4_URL` has a path, `BB4_USER` is not a plain name, or a port is not a valid port, the module is left out of that start with the reason. Then agentbox adds nothing to squid. `AB_UPGRADE=1` rebuilds the image on a fresh base. Maintainers update the pinned packages with `cd mcp/bb4/devtools && npm install --package-lock-only --ignore-scripts` after they change a version in `package.json`. They check the lock file with `trivy fs mcp/bb4/devtools` and `npm audit`, and review its diff. The same overrides as for the Tabularis bridge apply, and the same known issue too (zod 3 in supergateway, see [Tabularis (MCP)](#tabularis-mcp)).

#### Disable

Remove `bb4` from `AB_MCP`. The next start removes the sidecars and removes the host from squid's allowlist. The browser on the server does not change. The secrets stay until you remove them (or until `agentbox uninstall --all` removes them): `podman secret rm bb4_mcp_caller bb4_bridge_key`. To remove the image, use `podman rmi localhost/agentbox-bb4-devtools` (`agentbox uninstall` also removes it).

### Documentation (Context7)

The knowledge of the model stops at its training date. `WebFetch` cannot open documentation sites, because squid blocks them. [Context7](https://github.com/upstash/context7) (by Upstash) closes this gap. It is an MCP server with two tools: `resolve-library-id` (library name → Context7 ID) and `query-docs` (current documentation and code examples for that library, optionally for a specific version). The agent connects only to `mcp.context7.com`, never to arbitrary pages. The `agents/AGENTS.md.example` template tells both agents to look there first.

#### Setup

None: Context7 is the `context7` module, which is always enabled. Through the module, its host `mcp.context7.com` goes into squid's allowlist, and both agents get the server. To check, use `/mcp` in a session.

agentbox uses no API key: the anonymous tier has lower rate limits but needs no secret. If the limits cause problems, put the key in an nginx sidecar, as agentbox does for the Graylog token. Then the key never enters the agent container.

#### Things to watch

- **Queries leave the box.** Library names and questions go to Upstash. Write them as you write a search query, without code or data from the repo.
- **Documentation is third-party text.** Anyone can add a library to Context7, so its content is a prompt injection source, like PyPI or public GitHub.
- **A planted key is a write path.** Context7 accepts bearer keys. As with the other allowlisted APIs (see [Security model](#security-model)), a key that prompt injection plants would send queries to the account of another person.
## In the box

### Python

The image has [uv](https://docs.astral.sh/uv/) and preinstalled interpreters, so Python projects work in the box without any setup.

| | |
|---|---|
| Interpreters | `AB_PYTHON_VERSIONS` in `config.env` (default `3.12 3.13 3.14`, from the `Containerfile`). The build installs them into `/opt/uv-python`. They are on `PATH` as `python3.12`, `python3.13`, `python3.14`. The system `python3` is the 3.13 of Debian 13; the virtualenv of graphify uses it |
| Packages | `uv add`, `uv sync`, `uv run` and `pip` in a venv work, because PyPI is in the egress allowlist |
| Virtualenv | One per repo, **outside the repo**, in `ab-cache` (`~/.cache/venvs/<repo>-<hash>`), set through `UV_PROJECT_ENVIRONMENT`. Both agents share it |
| uv cache | In `ab-cache`. It stays across sessions, and both agents share it |

You cannot download interpreters at runtime (`UV_PYTHON_DOWNLOADS=never`; also, their source, GitHub, is blocked). For another version, list it in `AB_PYTHON_VERSIONS` (all the versions that you want, for example `3.11 3.12 3.13 3.14`). The next start rebuilds the image.

**Why the venv is outside the repo.** A `.venv` that the container creates points at `/opt/uv-python/...`, which does not exist on the host. A host `.venv` points at host paths. A shared directory breaks whichever side used it last. With `UV_PROJECT_ENVIRONMENT`, `uv` in the box never touches `<repo>/.venv`, so you can continue to use your host venv at the same time. This does not cover projects that do not use uv (plain `python -m venv .venv`); create such venvs outside the repo too, for example under `~/.venvs`.

**PyPI is a trade-off.** It lets the agent install packages on its own. This is convenient, but it is also the way that a malicious or typo-squatted package can get into the box. The damage stays in the box (no host credentials, no other egress), but the code that it writes goes into your repo. Review `pyproject.toml` / `uv.lock` changes in your diffs. To make dependency changes go through you, leave `pypi` out of `AB_EGRESS` (see [Egress](#egress)); then run `uv sync` one time from a container with internet access, or add packages on the host.

### Go

The image has the Go toolchain and [golangci-lint](https://golangci-lint.run). Both come from the official release archives, and the build verifies them against their published SHA-256 checksums.

| | |
|---|---|
| Versions | `AB_GO_VERSION`, `AB_GOLANGCI_LINT_VERSION` in `config.env` (defaults from the `Containerfile`). The Go default is `1.26`. A minor version means its latest stable patch release at build time. An exact version (`1.26.3`) pins it. An empty value means the latest stable Go. An empty golangci-lint version (the default) means the latest release at build time. `AB_UPGRADE` gets the versions that these values resolve to; the build log prints what it installed |
| Modules | `proxy.golang.org` and `sum.golang.org` are in the egress allowlist, so `go mod download`, `go get` and `go build` work |
| Caches | The module cache is in `ab-go` (`~/go`), and the build cache is in `ab-cache`. Both stay across sessions, and both agents share them |
| Tools | `go install pkg@version` puts the tool in `~/go/bin`, which is on `PATH` |
| Toolchain switching | Off: `GOTOOLCHAIN=local`. If a `go.mod` needs a newer Go, `go` fails with a clear error and does not download a toolchain. Rebuild with `AB_UPGRADE=1` |
| cgo | On: `gcc` and `libc6-dev` are in the image, so `go test -race` works and packages with C code build |
| make | Installed, so the `Makefile` targets of a project run. Targets that need podman/docker or hosts outside the allowlist do not run |

Things to know:

- **Private modules** (`GOPRIVATE`, the repositories of your organisation) come directly from the git host with credentials. The box does not have these credentials. Run `go mod vendor` on the host, and build with `-mod=vendor` in the box.
- **golangci-lint and the Go version.** The Go version that builds golangci-lint must be the same as or newer than the one that your `go.mod` targets. If you keep both versions on "latest", they stay in step. If you pin one, pin the other to match.
- **Same trade-off as PyPI.** The module proxy lets the agent add dependencies on its own. `sum.golang.org` guarantees that you get the same code as everyone else for a given version. It does not guarantee that the code is safe. Review `go.mod` / `go.sum` changes. To keep dependency changes on the host, leave `go` out of `AB_EGRESS`.
- `govulncheck` needs `vuln.go.dev`, which is not in the allowlist.

### Graphify

[graphify](https://github.com/Graphify-Labs/graphify) makes a knowledge graph of the repo that you can query. It is a Python CLI plus a `/graphify` skill that calls the CLI. Thus, unlike plain skills, it must be **in the image**: the agent cannot install it from PyPI.

The `Containerfile` installs it into `/opt/graphify` and makes it available as `/usr/local/bin/graphify`. `GRAPHIFY_VERSION` pins the version. `AB_GRAPHIFY_EXTRAS` in `config.env` sets optional extras (none by default), for example `[terraform]` for Terraform/HCL (`.tf`, `.tfvars`, `.hcl`) or `[sql,terraform]`. A change to either setting rebuilds the image at the next start.

#### The skill

`run.sh` installs the `/graphify` skill from the image, so the skill always matches the CLI in the image. It runs `graphify install` into a scratch home and copies the result (`SKILL.md` plus its `references/`) to `skills/graphify/` for Claude Code. It copies the pi variant to `~/.cache/agentbox/graphify-pi/graphify/`, which pi sessions mount over the shared one. It records the image ID next to the skill and refreshes both copies when the image changes, for example after a rebuild with a new `GRAPHIFY_VERSION`. If `run.sh` did not install a `skills/graphify/`, `run.sh` does not change it and shows a warning.

agentbox does not use the `~/.claude/CLAUDE.md` pointer that `graphify install` writes on a normal host: Claude Code finds the skill in `~/.claude/skills` on its own.

#### Enable it in a repo

The skill needs no setup per repo: `/graphify .` builds the graph into `graphify-out/`. Add `graphify-out/` to `.gitignore`.

Optionally, run this in a session:

```bash
graphify claude install         # graphify section in CLAUDE.md, plus a Claude Code PreToolUse hook in .claude/settings.json that nudges the agent to query the graph before grep/read
```

These are Claude Code hooks, not git hooks. You cannot install the git hooks of graphify (`graphify hook install`) in the box; see below.

If you set up a repo earlier with `graphify install --project`, the repo has its own copy in `.claude/skills/graphify/` and a pointer block in `.claude/CLAUDE.md`. Then `/graphify` exists two times. Delete the directory and the `# graphify` block in `.claude/CLAUDE.md` manually. Do not use `graphify uninstall`: it also removes the `graphify claude install` setup, the `AGENTS.md` sections and the git hooks.

#### What works in the box

- **Code graph:** fully local (tree-sitter), no network. It was verified offline with `graphify extract . --code-only`.
- **Docs, PDFs, images:** in the `/graphify` skill, the semantic pass uses the Claude session itself, so it works on your subscription. Headless `graphify extract` on docs needs an API key and does not work in the box; use `--code-only` there.
- **Queries:** `graphify query`, `path`, `explain` on `graph.json`.

What does **not** work, by design: `/graphify add <url>`, `graphify clone` and video/URL transcription (no internet), `graphify prs` (no `gh`), and `graphify hook install` (`.git/hooks` is read-only, so graphify git hooks can never run code on the host). After larger changes, ask the agent to run `graphify update .` instead.

#### Things to watch

- **The hooks contain an absolute path.** `graphify claude install` writes `/usr/local/bin/graphify hook-guard ...` into `.claude/settings.json`. If you also open this repo with Claude Code on the host, those hooks run **on the host**. They need graphify at that same path there; if it is not there, they fail.
- **`.claude/settings.json` and `CLAUDE.md` are shared if you commit them.** Hooks in a committed `settings.json` run for every colleague who opens the repo with Claude Code. Decide deliberately whether to commit them. To keep them out of git, use `.git/info/exclude` on the host.
- graphify creates `.claude/settings.json.graphify-bak` when it edits settings. Do not commit this file.
- The image disables the query log (`GRAPHIFY_QUERY_LOG_DISABLE=1`).

### Trivy

[Trivy](https://trivy.dev) scans the repository in the box. `trivy fs .` finds known vulnerabilities in dependencies (lock files, `go.mod`, ...). `trivy config .` finds misconfigurations in Terraform, Dockerfiles, Kubernetes manifests and similar files. It is off by default. To enable it, set it in `config.env` and rebuild:

```
AB_TRIVY=1
```

```bash
AB_UPGRADE=1 agentbox
```

- **The database stays outside the session.** Trivy downloads its vulnerability database as an image from `mirror.gcr.io` or `ghcr.io`. The session cannot reach those registries, because a registry also accepts uploads. `run.sh` gets the database the same way as the agent update: in a short-lived container, at most every 6 hours (`AB_UPDATE=1` forces it). It puts the database into the `ab-trivy` volume, which the session mounts read-only.
- **No downloads in the session**: `TRIVY_SKIP_DB_UPDATE`, `TRIVY_SKIP_JAVA_DB_UPDATE`, `TRIVY_SKIP_CHECK_UPDATE`, `TRIVY_SKIP_VERSION_CHECK`, `TRIVY_SKIP_VEX_REPO_UPDATE` and `TRIVY_DISABLE_TELEMETRY` are set (the database update also runs with telemetry off). The scan cache stays in memory (`TRIVY_CACHE_BACKEND=memory`). The misconfiguration checks are the ones built into the Trivy binary. The Java database is not used, so Trivy does not check Java artifacts for vulnerabilities.
- **Version**: `TRIVY_VERSION` in the `Containerfile` pins it. The build installs it from the release archive after a checksum check.
- CI scans the images of agentbox with Trivy every day (`.github/workflows/scan.yml`). The run summary shows a report of fixable HIGH and CRITICAL issues, so that you can decide when to rebuild. The scan never fails the build.

## Your projects

### Local services

To let the agent use your dev containers (Redis, RabbitMQ, PostgreSQL, ...), list them in `config.env`:

```
AB_SERVICES=redis rabbitmq postgres
```

On start, `run.sh` attaches each one to `ab-services`. This is a separate `--internal` network that the session joins. The agent connects by container name and the container's own port: `redis:6379`, `rabbitmq:5672` (management UI `rabbitmq:15672`), `postgres:5432`. Ports published on the host (`-p`) are not used and not necessary. The session's `NO_PROXY` contains the service names, so HTTP clients reach them directly, not through squid.

- You can attach only **rootless Podman** containers of the same user. Rootless Podman networks cannot see Docker or rootful containers. For those, run a copy under rootless Podman.
- The container must be on a **bridge network**. Rootless containers that start without `--network` use `pasta` and cannot join another network later (`"pasta" is not supported: invalid network mode`). Recreate them one time with `--network podman` (the default bridge network; `-p` and volumes work as before). Then `run.sh` attaches them to `ab-services` on the next start:

  ```bash
  podman inspect --format '{{.HostConfig.NetworkMode}}' redis   # pasta -> needs recreating
  podman stop redis && podman rm redis      # data survives only if it is in a volume
  podman run -d --name redis --network podman -p 6379:6379 -v redis-data:/data docker.io/library/redis:7
  ```
- The attachment stays, also when the container restarts. To undo it, run `podman network disconnect ab-services <name>`.
- `run.sh` starts a stopped service (`podman start`), and the service continues to run after the session ends. `run.sh` does not wait until the service is ready: a database that still initialises refuses connections for a few seconds.
- The services cannot reach the MCP/LLM sidecars. The session gets no route to the host or the internet through them. But a service that itself has internet access (for example a RabbitMQ shovel) could still be told to send data out. Use only plain dev instances as local services.
- **The agent gets full access to that data** with the credentials that you give it. Use dev data and dev passwords. Put connection settings in a [per-project environment](#per-project-environment) file.
- Clients: the image has Python and Go, so `uv run --with redis`/`psycopg`/`pika` works. `psql` and `redis-cli` are not installed.

### Test servers

To let the agent use databases, queues and other TCP services outside the box, for example on test servers, give each one a name and a target:

```
# config.env: for every session
AB_FORWARD=db=db.test.example:5432

# env/<repo dir name>.conf: only for sessions in that repo
AB_FORWARD=mq=mq.test.example:5672 cache=redis.test.example:6379
```

The agent connects by name and the port of the target: `db:5432`, `mq:5672`. For each target, `run.sh` starts a sidecar that runs `socat` on the agentbox image. The sidecar is on `ab-egress` (the way out) and on an `--internal` network that the session joins. On that network, it answers to the name:

| List | Network | Sidecars |
|---|---|---|
| `config.env` | `ab-forward` | `ab-fwd-<name>` |
| `env/<repo dir name>.conf` | `ab-fwd-<key>`; only sessions in that repo join it | `ab-fwd-<key>-<name>` |

`<key>` comes from the path of the repo, so the sessions of another repo cannot reach these targets. The repo file uses the same `KEY=VALUE` format as `config.env` and accepts only `AB_FORWARD`. It is with the [per-project environment](#per-project-environment) files, outside the repo: thus the agent cannot add targets for its next session.

- **Needs socat in the image.** If an image is from before agentbox added socat, the next start rebuilds it. If a start with forwards still says that socat is missing, run `AB_UPGRADE=1 agentbox`.
- **Plain TCP.** The target sees connections from your host, through your network and VPN, like any other client there. TLS (`sslmode=require`, `amqps`) goes end to end. The certificates name the real host, so clients that verify host names need explicit settings (for example `sslrootcert` with `sslmode=verify-ca` instead of `verify-full`).
- **Names** contain only lowercase letters, digits and hyphens. They must not start with `ab-`, and they must be unique across both lists and `AB_SERVICES`. The session's `NO_PROXY` contains them, so HTTP clients connect directly.
- **Changes** apply at the next start: changed targets get new sidecars, and the sidecars of removed targets are removed. The sidecars of a repo change only when a session starts in that repo. Sidecars continue to run between sessions. `socat` opens a connection to the target only when the agent opens one.
- **HTTP(S) services** with a public or internal host name are simpler as an [egress group](#egress): then the certificate matches.
- **The agent gets full access to that data** with the credentials that you give it. Use test accounts with the least rights. Put them in the [per-project environment](#per-project-environment) file.

### Per-project environment

Environment variables for one project go in `~/.config/agentbox/env/<repo dir name>.env`; only sessions in the box see them:

```
# env/myapp.env
DB_CONN=host=postgres port=5432 user=dev dbname=myapp_test sslmode=disable password=dev
AMQP_URI=amqp://dev:dev@rabbitmq:5672/%2f
```

`run.sh` gives the file for the mounted directory to the session with `--env-file` and prints its path on start. If there is no file, `run.sh` passes nothing. Changes apply at the next session start.

- Different projects can use the same variable names with different values. The agent on the host never sees them.
- Podman format: one `KEY=VALUE` per line, and `#` comments. The value is literal (quotes become part of it). A line with only `KEY` copies that variable from the host environment.
- The directory name is the key of the file: two repos with the same name share one file.
- The directory is on the host and is not mounted. Thus the agent cannot change what its next session starts with, and the passwords never go into the git of the project.
- The variables that `run.sh` sets itself (proxy, agent settings) have priority, and the file cannot override them.
- `AB_ENV_DIR` sets a different directory.

## Maintenance

### Releases

Versions are git tags `vX.Y.Z`, each with a section in `CHANGELOG.md`. A release on GitHub contains `agentbox-vX.Y.Z.tar.gz` and `agentbox-vX.Y.Z.tar.gz.sig`. `git archive` makes the archive, so it contains exactly what git tracks, with the version written into `VERSION`. The `.sig` file is an SSH signature (`ssh-keygen -Y sign`, namespace `agentbox-release`).

| Command | What it does |
|---|---|
| `agentbox version` | Shows the version that you run; `dev` in a clone |
| `agentbox update` | Finds the latest release and downloads it. Verifies the signature against `release/allowed_signers` of the version that you run now. Shows its CHANGELOG section. After you confirm, installs it next to the old one (`--yes`: no question) |
| `agentbox rollback` | Goes back to the version before the last switch |
| `agentbox uninstall` | Removes agentbox from the host; see [Uninstall](#uninstall) |

`check-updates.sh` tells you about a newer release, at most every 6 hours; it never installs one. Installed versions are read-only; `agentbox uninstall` removes them with the rest.

**Trust.** agentbox accepts an update only if a key in the `release/allowed_signers` of the running version signed it. Thus a new signing key becomes trusted only through a release that a trusted key signed. A compromised GitHub account alone cannot ship an update. The first install has nothing to compare with: check the signature yourself (Install) against this key:

```
kuza namespaces="agentbox-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUXjyDJluvnJbz14VtB4pBbNA29xyauZarIyDlEPSR2
```

Fingerprint `SHA256:KESk+phlkaooJLO6Kk6vP2qWGmGrYrFmU66JIcJ3YBY` (ED25519). To check it, run `ssh-keygen -lf` on a file that holds the key part of that line. The same line is in `release/allowed_signers`.

**Development.** Work in a clone, and open that clone in the box like any repository. For your daily work, run agentbox from an installed release or from a second clone. `run.sh` refuses to mount the copy that it runs from, because a session could change code that runs on the host.

**Publishing** (maintainers): add a `## vX.Y.Z` section to `CHANGELOG.md`, then commit and push. Then, on the host, run:

```bash
./release.sh vX.Y.Z
```

It checks the version, the clean and pushed `main`, the CHANGELOG section and the tests. It also checks that your signing key (`AB_RELEASE_KEY`, else `git config user.signingkey`, else `~/.ssh/agentbox-release`) is in `release/allowed_signers`. Then it makes a signed tag, the archive and its signature in `dist/`, and verifies the signature the same way as `agentbox update`. After you confirm, it pushes the tag and creates the GitHub release with `gh`. To add a new signing key to `release/allowed_signers`, use a release that a key already in the list signed.

### Updates

| What | Updates how | Command |
|---|---|---|
| Claude Code, pi | **Automatically**, at most every 6 hours, in a separate short-lived container, each into its own volume | `AB_UPDATE=1 agentbox` / `AB_UPDATE=1 agentbox pi` to force |
| Sidecar images (`mcp-grafana`, `github-mcp-server`, nginx) | **Checked at most every 6 hours**, updated after you confirm (see below). podman never pulls an image again on its own | Answer `y` at the prompt, or run `AB_UPGRADE=1 agentbox` |
| Base image (Debian packages, git, Python) and the squid image (the squid of Debian, `Containerfile.squid`) | Built here, so only when you ask: a cached build never runs `apt-get` again. The update check reminds you when the base image of their last build was pulled a month ago | `AB_UPGRADE=1 agentbox` |
| graphify | Pinned in `Containerfile` | Increase `GRAPHIFY_VERSION`; the next start rebuilds |
| Trivy | Binary pinned (`TRIVY_VERSION` in `Containerfile`); its database **automatically**, at most every 6 hours, outside the session | Increase `TRIVY_VERSION`; the next start rebuilds. `AB_UPDATE=1 agentbox` gets the database now |
| Go, golangci-lint | Go: latest 1.26.x at build time; golangci-lint: latest. `Containerfile` sets both | `AB_UPGRADE=1 agentbox` |
| uv, Python interpreters | Pinned in `Containerfile` | Increase `UV_VERSION` in `Containerfile` / set `AB_PYTHON_VERSIONS`; the next start rebuilds. The uv version decides which patch release of each version the build installs, so increase `UV_VERSION` to get newer patch releases |
| Skills from sources (`AB_SKILLS`) | **Checked at most every 6 hours**, updated after you confirm (see below); pinned sources (`REF`) are skipped | Answer `y` at the prompt, or change `REF` |
| Tokens (Claude, Grafana, Graylog, GitHub, Woodpecker) | They expire on their own schedule | `agentbox login` for Claude Code; for a module, `e <number>` in `agentbox setup` (or recreate the Podman secret). The next start recreates the sidecars that hold it |

`AB_UPGRADE=1` does all of this in one run: it pulls the sidecar images, rebuilds the base image from scratch (`--pull --no-cache`), updates Claude Code and recreates the sidecars. It does not change volumes, secrets or MCP registrations. A good interval is one or two weeks. It takes a few minutes because of the full rebuild.

You do not need it after you change a build setting (`AB_TRIVY`, `AB_PYTHON_VERSIONS`, `AB_GO_VERSION`, `AB_GOLANGCI_LINT_VERSION`, `AB_GRAPHIFY_EXTRAS`) or after an agentbox update that changed a `Containerfile`. Each image carries a fingerprint of its `Containerfile` and build settings (label `agentbox.build`). If the fingerprint differs, the start rebuilds that image as a cached build, not from scratch.

#### Update check

`run.sh` runs `check-updates.sh` before it starts the sidecars, at most every `AB_UPDATE_EVERY` seconds (6 hours by default, the same interval as the agent update). Only a check that finds nothing to update resets the interval. If you decline an update, an update fails or a registry is not reachable, the next session checks again. If you run `./check-updates.sh` manually, it always checks.

- **Sidecar images.** For each agentbox sidecar container, it asks the registry for the digest of the image tag and compares it with the local image. This is an anonymous `HEAD` request: it pulls nothing and does not count against the pull limit of Docker Hub. It also reports sidecars that still run an image older than the local one. If you answer `y`, it pulls the new images and removes the affected sidecars, and `run.sh` recreates them immediately. Other open sessions lose those MCP servers until they restart.
- **Vendored skills.** `sync-skills.sh` records each sync in `skills/.sources/<owner>__<repo>` (URL, installed commit, `SKILLS_ONLY`, prefix, source, pin, installed names). The check compares that commit with the remote default branch (`git ls-remote`). It prints a GitHub compare link to read before you update. On `y`, it does the sync again with the same settings.

Without a terminal (`run.sh -p ...` from a script), it only prints what is out of date. A failed check (no network, registry down) prints a warning and does not stop the session. `AB_CHECK_UPDATES=0` skips it. `AB_UPGRADE=1` also skips it, because that updates the images anyway. To check without a session start, run `./check-updates.sh` alone.

A session that has the agentbox directory mounted can write to the skills directory. Thus the check reads the records as data, accepts only `https://` URLs, and runs git outside any repository. As a result, a hook or config planted in the box does not run on the host. For the same reason, `sync-skills.sh` makes a new clone in a scratch directory.

#### Claude Code

`run.sh` updates it at most one time every 6 hours: a container with internet access, but without the repo or the agent, runs `npm install -g @anthropic-ai/claude-code@latest` into `ab-claude-tools`.

```bash
AB_UPDATE=1 agentbox                # force an update now
AB_UPDATE_EVERY=86400 agentbox      # change the interval (seconds)
```

To pin a version, change `@latest` in `run.sh` to `@x.y.z`. Then run with `AB_UPDATE=1`.

#### graphify

Before you increase the version, check the latest release and what changed:

```bash
curl -s https://pypi.org/pypi/graphifyy/json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])'
```

Set `GRAPHIFY_VERSION` in `Containerfile`. The next start rebuilds the image. The same run also installs the `/graphify` skill again from the new image (see [The skill](#the-skill)).

#### Pinning sidecar images

The sidecars use floating tags (`:latest`, `:alpine`), so an upgrade can change their behaviour. This happened with the caller-auth and Host checks of mcp-grafana. To control this, pin tags in the `IMG_*` variables at the top of `run.sh`, and change them deliberately. Squid is not pulled: `Containerfile.squid` builds it here from Debian (`localhost/agentbox-squid`). Thus its packages are as current as the last `AB_UPGRADE=1`.

### Disk space

`run.sh` removes its own unused items:

- **Replaced images.** An upgrade (`AB_UPGRADE=1`, or `y` in the update check) leaves the previous agentbox image and sidecar images as `<none>`. The next start removes them when no container uses them. If an open session uses the old agentbox image, the image stays until a later start. `~/.cache/agentbox/retired-images` lists the images that wait for removal. Builds keep no intermediate images (`--layers=false`), so a failed build starts again from the beginning.
- **Sidecars.** On start, `run.sh` removes the sidecars of MCP modules that are no longer in `AB_MCP`, and `ab-llm-openai` when its key is gone. When `run.sh` recreates a sidecar, it also removes the anonymous volumes of the sidecar (squid declares some).

The cleanup does not touch images and volumes from before it existed, or from other projects. `podman system df` shows the totals. `podman image prune` removes images without a name, from any project. `podman volume prune` removes unused volumes; in older podman versions, it also removes named volumes. First, check `podman volume prune --help` and `podman volume ls --filter dangling=true`.

The cache volumes grow on purpose, so that sessions do not download the same dependencies again: `ab-cache` (uv cache, Go build cache, per-repo virtualenvs) and `ab-go` (Go modules). If no session runs, `podman volume rm ab-cache ab-go` empties them; the next sessions fill them again.

### Uninstall

```bash
agentbox uninstall
```

It lists what it removes and asks before it removes anything:

- containers, volumes and networks with names `ab-*`. Open sessions end. Claude Code and pi, with their logins, session history and caches, are removed with the volumes. Your own containers on `ab-services` ([Local services](#local-services)) are only disconnected, never removed;
- the host services that MCP modules started (systemd user services `agentbox-*`, for example the [Tabularis](#tabularis-mcp) bridge);
- the images of agentbox: `localhost/agentbox`, `localhost/agentbox-squid` and the sidecar images;
- the cache `~/.cache/agentbox` and its stamps;
- git-guard (`~/.local/bin/git`, only if it is git-guard: then your system git is used again) and `~/.config/environment.d/agentbox.conf`;
- the command `~/.local/bin/agentbox`, its bash completion and the installed versions in `~/.local/share/agentbox`.

Then it asks two more questions. The default answer to each is no:

- the Podman secrets that agentbox and its modules use (`claude_oauth`, `openai_api_key`, the MCP tokens and caller tokens);
- your files in `~/.config/agentbox`: `config.env`, `env/` with passwords, your skills, `AGENTS.md`, local modules.

`agentbox uninstall --yes` removes without questions, but keeps the secrets and your files. `--yes --all` removes those too. It does not touch the repositories that you opened in the box. If you use a clone, run `./agentbox uninstall` in it. The clone itself stays; delete it yourself.

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
| The session cannot read some files of the repo, or all of it (`Permission denied`); `git status` in the box lists files as modified that nobody changed, or `git add` fails | Another podman container mounted them with `:Z`, which gives them an SELinux label private to that container. A typical cause: your own `podman run -v .:/dst:Z ...` in the repo. For code that you also open in the box, use lowercase `:z` (shared label). If the whole repo got a new label, the next session start restores it. Single files stay private, because podman does not relabel a volume that it already relabeled with `:z`. Restore them on the host: `chcon -R -t container_file_t -l s0 <path>`. The sidecars and sessions of agentbox mount copies of the agentbox files from the cache, so they do not cause this. Also, the files of an installed version are read-only, so podman cannot relabel them |
| `missing podman secrets` | No Claude Code token yet: `agentbox login`. |
| `MCP module '...' left out of this session` | The reason follows. A missing setting or secret: `agentbox setup` adds them. A failed start: the error above shows the cause. No such module in this version: it is from another version, or `AB_MCP` has a typo. Its `mcp.sh` does not parse: `bash -n` on it shows where. No URL: the setting that gives the URL is empty. A server in its `MCP_SERVERS` that does not have the correct form, `caller` without `MCP_CALLER_SECRET`, or a server name that another module also has: fix the `mcp.sh` of the module. The session starts without the module. |
| Claude shows the login picker or says it is not logged in | See [Token not picked up](#token-not-picked-up). |
| `Unable to connect to Anthropic services` / `ERR_PROXY_TUNNEL` | Squid blocked a necessary host. The error names it. Find `DENIED` in the squid log, and add the host to a group in `egress.local.d/` (see [Egress](#egress)). The next start recreates squid. |
| Build or test commands fail to download dependencies | The package registry for your language is not in the allowlist. PyPI is allowed. Add other registries deliberately: each one makes egress wider. |
| `go: go.mod requires go >= 1.X (running go 1.Y; GOTOOLCHAIN=local)` | The Go in the image is older than the project needs. Run `AB_UPGRADE=1 agentbox` (or set a higher pinned `AB_GO_VERSION`). |
| `go` fails to fetch a module with a git or 410/404 error | It is a private module, or a module that is not on the public proxy. Vendor it on the host (`go mod vendor`). If the squid log shows `DENIED` for another host, the proxy redirected there; add that host deliberately. |
| pi (API key): `OpenAI API error (401)` | The API key in `openai_api_key` is not valid, or the sidecar rejected the caller token. In the second case, `podman logs ab-llm-openai` shows a 401 without an upstream request. If `llm_openai_caller` was recreated, the session started before that: start a new one. |
| pi (subscription): sign-in or requests fail with `ERR_PROXY_TUNNEL` / 403 | `openai` is not in `AB_EGRESS`. The squid log shows the denied host. |
| pi (subscription): browser shows "can't connect to 127.0.0.1:1455" after approving | This is expected: the callback listener is in the container. Copy the full URL from the address bar and paste it into pi. |
| pi (subscription): requests go to `ab-llm-openai` and fail | pi uses `pi/models.json`, which points pi at the sidecar, only when the `openai_api_key` secret exists. If not, pi gets a `models.json` without overrides. If you changed from API key to subscription, run `podman secret rm openai_api_key`. |
| pi (subscription): worked before, now fails after an update | Update pi (`AB_UPDATE=1 agentbox pi`). If you use the legacy "OpenAI Codex" provider, change to OpenAI → Sign in with ChatGPT. |
| An MCP server is `failed` in `/mcp` | Check the `podman logs` of its sidecar. Both agents list only enabled modules. Thus a failed module has a sidecar that should run, or (Context7) a host that squid should allow. |
| `claude mcp list` does not show grafana, graylog, ... | Expected: the servers of the modules come from `--mcp-config`, and `mcp list` ignores it. Use `/mcp` in a session. |
| `uv` says a Python version is not available and downloads are set to `never` | The image does not contain that version. Add it to `AB_PYTHON_VERSIONS` in `config.env`, and run `AB_UPGRADE=1 agentbox`. |
| Sidecar can't resolve Grafana/Graylog | Containers cannot see the internal DNS. Add `--dns <server>` or `--add-host` to the sidecar in `run.sh`. |
| `/mcp` shows a server as failed | Check the `podman logs` of the sidecar. |
| `podman logs ab-mcp-graylog` shows `POST /mcp ... 405 59` | The 59-byte body is the `HTTP 405 Method Not Allowed` API error of Graylog itself. Thus nginx works, but Graylog has no MCP endpoint there. Enable MCP in System → Configurations → MCP, and make sure that the Graylog version is 7.0+. |
| grafana in `/mcp` fails with `403 ... forbidden: host not allowed` | mcp-grafana validates the `Host` header against `--allowed-hosts`. The list must include the name that Claude uses (`ab-mcp-grafana:8000`). Recreate the sidecar with `AB_RESTART=1`. |
| nginx sidecar exits on start | nginx resolves `GRAYLOG_URL` when it starts. Fix DNS, or use an IP address and check TLS/SNI. |
| Context7 fails in `/mcp` or its tools return proxy errors | Squid did not get the hosts of the modules. `podman exec ab-egress cat /etc/squid/agentbox-allow.conf` should list `mcp.context7.com`. `AB_RESTART=1 agentbox` recreates squid. |
| Context7 tools return 429 | Anonymous rate limit. Wait, or add an API key through a sidecar (see [Documentation (Context7)](#documentation-context7)). |
| github in `/mcp` fails with 401 | The session has an older `github_mcp_caller` than the sidecar (the secret was recreated after the session started). Start a new session. |
| github in `/mcp` fails with 502 | nginx cannot reach `ab-mcp-github-srv`. Check `podman ps` and its logs. If that container restarted alone, restart both with `AB_RESTART=1` (nginx caches its IP address). |
| GitHub tools fail with 403 / 404 | The PAT does not have the permission, the repository is not selected in it, or an org-owned token waits for approval. Writes to code fail, and this is expected: Contents is read-only. |
| `git fetch` / `git push` fail inside the box | Expected: the agent cannot reach GitHub. Run these commands on the host. |
| `git push -u`, `git remote add` fail | Expected: `.git/config` is read-only. Run these on the host. |
| Git does not work at all inside the box | The repo is a worktree or submodule (`.git` is a file). Its git directory is outside the mount. Start the box on the main checkout. |
| Write errors under `/opt/claude` | Claude Code must write to its install directory. Warning: the next step removes the tamper protection of the binary. Remove `:ro` from the `ab-claude-tools` mount. |

### Token not picked up

`run.sh` sets `hasCompletedOnboarding: true` in `~/.claude.json` (inside `ab-claude-home`) before every session. It does this because interactive Claude Code can ignore `CLAUDE_CODE_OAUTH_TOKEN` during first-run onboarding and show the browser login picker instead ([anthropics/claude-code#46259](https://github.com/anthropics/claude-code/issues/46259)). If the token still does not work, check the secret itself.

**1. Is the secret intact?** When you copy a long token from a terminal, the copy often gets a line break or spaces where the terminal wrapped the token.

```bash
podman run --rm --network none --secret claude_oauth,type=env,target=T \
  --entrypoint sh localhost/agentbox -c \
  'printf "length=%s prefix=%.14s\n" "${#T}" "$T"; printf %s "$T" | tr -d "[:graph:]" | od -c | head -2'
```

Expected: the prefix is `sk-ant-oat01-`, and the `od` output shows **no** characters (only `0000000`). Typical failures:

- the prefix looks like a shell command (`read -rsp ...`): you pasted the setup commands as a block, see step 5;
- a random-looking string without the `sk-ant-oat01-` prefix: you stored the browser authorization code instead of the token, see step 4;
- `\n` or spaces in the `od` output: the terminal wrapped the token and broke it.

Recreate the secret:

```bash
podman secret rm claude_oauth
read -rsp 'Claude token: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create claude_oauth -; echo; unset T
```

**2. Does the token work at all?** Headless mode skips onboarding entirely:

```bash
agentbox . -p "say ok"
```

- If the command works here but not interactively, the problem is in the onboarding. Run `podman run --rm -v ab-claude-home:/h --entrypoint cat localhost/agentbox /h/.claude.json` and make sure that the output contains `"hasCompletedOnboarding": true`.
- If the command fails here too, the token is invalid or expired. Create a new token (setup step 4). Then replace the secret.

**3. Stale login state in `ab-claude-home`.** If you once ran `/login` inside the box, the stored credentials can take precedence over the token. Run `/logout` in a session, or remove `/home/node/.claude/.credentials.json` from the volume.

## Reference

### Configuration reference

| Variable | Default | Meaning |
|---|---|---|
| `AB_HOME` | `~/.config/agentbox` | The directory with your files. See [Your files](#your-files) |
| `AB_CONFIG` | `<AB_HOME>/config.env` | The settings file. You can set all variables in this table there, except `AB_AGENT`, `AB_UPDATE`, `AB_RESTART`, `AB_UPGRADE`. `run.sh` accepts the settings of a module there only while the module is in `AB_MCP` |
| `AB_MCP` | unset | The MCP modules to enable, space- or comma-separated, for example `grafana graylog github`. `context7` is always on. See [MCP servers](#mcp-servers) |
| `AB_EGRESS` | `anthropic openai pypi go` | The egress groups to enable, space- or comma-separated, from `egress.local.d/` or `egress.d/`. An empty value enables no group. See [Egress](#egress) |
| `GRAFANA_URL` | unset | A setting of the `grafana` module: the Grafana base URL (needs the `grafana_sa` secret) |
| `GRAYLOG_URL` | unset | A setting of the `graylog` module: the Graylog base URL (needs the `graylog_basic` secret) |
| `AB_UPDATE` | unset | `1` forces a Claude Code update |
| `AB_UPDATE_EVERY` | `21600` | The time in seconds between automatic agent updates, and between update checks for sidecar images and vendored skills |
| `GH_TOOLSETS` | `context,repos,issues,pull_requests,actions` | A setting of the `github` module: the toolsets, which nginx enforces |
| `TABULARIS_CMD` | `tabularis` | A setting of the `tabularis` module: the command that runs Tabularis on the host. `--mcp` is appended to it. Use only letters, digits, spaces and `_./:=+-` |
| `WOODPECKER_URL` | unset | A setting of the `woodpecker` module: the base URL of Woodpecker, without `/api` (needs the `woodpecker_token` secret) |
| `WOODPECKER_CA` | unset | A setting of the `woodpecker` module: a CA certificate file for an https Woodpecker that your own CA signed |
| `TABULARIS_PORT` | `47821` | A setting of the `tabularis` module: the port of supergateway on `127.0.0.1` |
| `AB_SKILLS` | unset | The skill sources to enable, space- or comma-separated, from `skills.local.d/` or `skills.d/`. See [Skills](#skills) |
| `AB_SKILLS_DIR` | `<AB_HOME>/skills` | The personal skills directory, mounted read-only |
| `AB_GRAPHIFY_EXTRAS` | unset | The graphify extras baked into the image, for example `[terraform]`. If you change the value, the next start rebuilds the image. See [Graphify](#graphify) |
| `AB_TRIVY` | unset | `1`: the image contains Trivy. Its database is kept current outside the session. If you change the value, the next start rebuilds the image. See [Trivy](#trivy) |
| `AB_PYTHON_VERSIONS` | `3.12 3.13 3.14` | The Python interpreters baked into the image. If you change the value, the next start rebuilds the image. See [Python](#python) |
| `AB_GO_VERSION`, `AB_GOLANGCI_LINT_VERSION` | `1.26`, latest | The Go and golangci-lint versions in the image. An empty value means the latest release. If you change a value, the next start rebuilds the image. See [Go](#go) |
| `AB_SERVICES` | unset | Your own containers (space- or comma-separated names) attached to the `ab-services` network. The session reaches them by name. See [Local services](#local-services) |
| `AB_FORWARD` | unset | Services outside the box, `name=host:port`, space- or comma-separated. The session reaches them by name. You can also set it per repo in `<env dir>/<repo dir name>.conf`. See [Test servers](#test-servers) |
| `AB_ENV_DIR` | `<AB_HOME>/env` | The directory with the per-project environment files, `<repo dir name>.env`. See [Per-project environment](#per-project-environment) |
| `AB_AGENT` | `claude` | `pi` runs pi instead of Claude Code (`agentbox pi` sets this value). `shell` runs bash in the same box instead of an agent, with its own home volume `ab-shell-home`. The arguments go to bash: none for an interactive shell, a script, or `-c '...'` |
| `AB_UPGRADE` | unset | `1` pulls the sidecar images, rebuilds the base image, updates Claude Code and recreates the sidecars |
| `AB_RESTART` | unset | `1` recreates all sidecars. You rarely need it: a sidecar is recreated automatically when its settings, image tag, mounted files (nginx templates, `squid.conf`, egress hosts) or Podman secrets change |
| `AB_WARNINGS_ASK` | `1` | `0`: if the start shows warnings, agentbox asks no question before the session. It still prints the warnings. See [Daily usage](#daily-usage) |
| `BB4_URL`, `BB4_USER`, `BB4_DEVTOOLS_PORT` | unset, unset, `5100` | The settings of the `bb4` module: the base URL of the browser server (scheme, host, port), your user name on that server, and its DevTools WebSocket port. See [Remote browser (bb4)](#remote-browser-bb4) |
| `AB_CHECK_UPDATES` | `1` | `0` skips the check for newer sidecar images and vendored skills before a session. See [Update check](#update-check) |

agentbox starts each sidecar once and then uses it again. The next start recreates a sidecar if its settings, image tag, mounted files or Podman secrets changed. A secret also counts as changed when you create it again, for example with a renewed token. The next start also removes the sidecars of modules that are no longer in `AB_MCP`. To recreate all sidecars anyway:

```bash
AB_RESTART=1 agentbox .
```

### Files

| File | Purpose |
|---|---|
| `agentbox` | The command that `install.sh` links into `~/.local/bin`: `agentbox [repo]`, `pi`, `shell`, `login`, `setup`, `version`, `update`, `rollback`, `uninstall`. See [Releases](#releases) |
| `install.sh`, `release.sh` | `install.sh` installs an unpacked release; `release.sh` publishes a release (for maintainers). See [Releases](#releases) |
| `VERSION`, `CHANGELOG.md`, `release/allowed_signers` | The release version (`git archive` writes it), the changes per release, the keys that updates must be signed with |
| `run.sh` | The entry point: the steps in order (config, image, updates, sidecars, session). The steps themselves are in `lib/` |
| `lib/*.sh` | The steps of `run.sh`: settings, agent, sidecars, MCP modules, local services, skills, session |
| `mcp/<name>/` | MCP server modules, which you enable with `AB_MCP`: `mcp.sh` plus files such as nginx templates. See [MCP servers](#mcp-servers) |
| `config.env.example` | The settings template. Copy it to `~/.config/agentbox/config.env` |
| `pi.sh` | The same as `run.sh`, with pi as the agent (`AB_AGENT=pi`) |
| `pi/models.json` | The pi configuration: the model endpoint for API-key mode. Each start makes a copy in `~/.cache/agentbox/session/pi/` and mounts the copy read-only |
| `pi/llm-openai.conf.template` | The nginx config for the OpenAI sidecar (pi with an API key): it checks the caller and injects the API key |
| `Containerfile` | The base image (`node:24-trixie-slim`, Debian 13, Node.js 24 LTS): node, git, ripgrep, fd, make, gcc, uv with preinstalled Python versions, Go, golangci-lint, graphify |
| `Containerfile.squid` | The image of the egress proxy: Debian's squid, built here like the base image |
| `squid.conf` | The egress proxy settings and access rules. It includes a generated file with the allowed hosts |
| `egress.d/<name>.conf` | Egress groups (PyPI, Go modules, ...), which you enable with `AB_EGRESS`. See [Egress](#egress) |
| `agents/AGENTS.md.example` | The template for `~/.config/agentbox/AGENTS.md`: optional personal instructions for both agents in every repo, mounted read-only (Claude Code: `~/.claude/CLAUDE.md`, pi: `~/.pi/agent/AGENTS.md`) |
| `claude/statusline.py` | The Claude Code status line (context use, subscription limits, cost). A copy from `~/.cache/agentbox/session/claude/` is mounted read-only. Claude Code uses it unless you set your own `statusLine`. See [Status line](#status-line) |
| `skills.d/<name>.conf` | Skill sources (git repositories of skills), which you enable with `AB_SKILLS`. See [Skills](#skills) |
| `completions/agentbox.bash` | Tab completion for the `agentbox` command in bash. The install and every update link it into `~/.local/share/bash-completion/completions/` |
| `git-guard` | A host-side git wrapper, installed as `~/.local/bin/git`. It refuses repositories whose `.git` a session redirected. See [Git on the host](#git-on-the-host) |
| `sync-skills.sh` | Host-side: it installs a skills repository into your `skills/` (flattened). `run.sh` runs it for the sources in `AB_SKILLS` |
| `check-updates.sh` | Host-side: `run.sh` runs it at most every 6 hours. It finds newer sidecar images and vendored skills and offers to update them |
| `tests/run.sh` | Tests for `run.sh`, `check-updates.sh` and `sync-skills.sh` with a podman stand-in. See [Tests](#tests) |

#### Your files

Your settings and data are apart from the code, in `~/.config/agentbox/` (`AB_HOME` changes this location). Thus you can replace the code with a new version or a fresh clone, and your files stay unchanged. Also, a session that has agentbox's own code open as its repo does not see them. In this README, `config.env`, `env/` and the other files below mean the files in this directory.

| File | Purpose |
|---|---|
| `config.env` | The settings, made from `config.env.example` |
| `env/` | Optional. The per-project environment files, `<repo dir name>.env`, and the per-project settings, `<repo dir name>.conf` (`AB_FORWARD`, see [Test servers](#test-servers)) |
| `skills/` | Optional. Personal skills, mounted read-only into the agent. `skills/.sources/` records which skills `sync-skills.sh` installed and from where |
| `AGENTS.md` | Optional. Personal instructions for both agents, made from `agents/AGENTS.md.example` |
| `mcp.local/<name>/` | Your own MCP modules. A module with the name of a module in `mcp/` replaces that module |
| `skills.local.d/<name>.conf` | Your own skill sources |
| `egress.local.d/<name>.conf` | Your own egress groups |
| `dbhub.toml` | Optional. The databases of the `dbhub` module, with their passwords; mode 600. See [DBHub (MCP)](#dbhub-mcp) |
| `pi-extensions/` | The pi extensions that you allow, mounted read-only. The first start of pi creates it empty |

`run.sh` refuses to mount a repo that is, contains or lies inside one of these: agentbox's code, any installed version (`~/.local/share/agentbox`; `agentbox rollback` would run it), git-guard (`~/.local/bin/git`), or the files above. Otherwise, a session could change code that runs on your host, or read your passwords. To work on agentbox itself, open a separate clone of it.

Older versions kept these files next to the code (`agents/AGENTS.md` for `AGENTS.md`, `pi/extensions/` for `pi-extensions/`). If one of these files is still there, `run.sh` stops before it starts anything. It prints the commands that move the file.

### Tests

```bash
./tests/run.sh            # all tests
./tests/run.sh test_mcp_  # tests whose name starts with test_mcp_
```

The tests need no podman, network or registry: `tests/stub/podman` replaces podman and records every call. Fake `curl` and `git ls-remote` replace the registries and GitHub, and `sync-skills.sh` clones a local repository. Each test works on a copy of agentbox's code in a scratch directory, never on your `config.env` or `skills/`. The tests check what `run.sh` asks podman to do (sidecars, secrets, the session's mounts and arguments), the generated MCP configs, and the error paths.

The tests need bash 4+ and git. The JSON checks need python3; without it, the tests skip them.

Run the tests after you change `run.sh`, `lib/`, a module in `mcp/`, `check-updates.sh` or `sync-skills.sh`. If you add a new module or setting, add a test for it next to the existing tests in `tests/run.sh`.

#### Escape checks

`tests/run.sh` checks what `run.sh` asks podman to do, not what a session can actually reach. `tests/escape.sh` checks that from the inside, in a real box. It needs no agent: `AB_AGENT=shell` runs bash in the same box instead.

```bash
agentbox shell ~/src/agentbox tests/escape.sh   # a clone of agentbox as the repo
```

It also works in an agent's session (`bash tests/escape.sh` with the agentbox repo open).

It tries the same things as an agent under prompt injection:

- direct connections and DNS around the proxy;
- the host and the network gateways;
- disallowed hosts, IP addresses and other ports through the proxy;
- the sidecars through the proxy and without their caller tokens;
- container runtime sockets;
- credentials in the home directory and the environment;
- privileges;
- writes to everything mounted read-only.

PASS means that the attempt failed. FAIL means a hole, and the exit status is 1. WARN lines are not holes by themselves. The script changes nothing: it only tries connections and reads, and it makes a scratch file that it removes again.

Run it after you change networks, squid, sidecars or the session's mounts. Also run it on a new host. `ESCAPE_FORBIDDEN` adds targets that must not be reachable, and `ESCAPE_REACHABLE` adds targets that must be reachable. Both take space-separated `host:port` values.

#### CI

GitHub Actions runs both on every push to `main` and on every pull request:

- `.github/workflows/checks.yml`: `tests/run.sh` and `shellcheck`. They take about a minute.
- `.github/workflows/box.yml`: a real box on the runner's rootless podman. It builds the image, starts squid and the `AB_FORWARD` sidecars of two repos, and runs `tests/escape.sh` in a session of one repo. The forward sidecar of the other repo is a target that must stay out of reach. This workflow also runs daily, to find failures that outside changes cause (new squid or nginx images, podman or Ubuntu updates on the runner).

The workflows have read-only access to the repo and no secrets. The actions are pinned to a commit, not a tag.

### Not yet verified

These parts come from documentation and from tests against fake upstreams. Nobody ran them end to end yet:

- pi through the OpenAI sidecar against the real OpenAI API. The chain pi → nginx (caller check, key injection) → upstream was tested with a fake upstream.
- pi's *Sign in with ChatGPT* through squid with the pasted callback URL, and token refresh with `PI_OFFLINE=1` set.
- Context7 through squid from pi (it works from Claude Code).
