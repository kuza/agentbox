# agentbox

Run [Claude Code](https://code.claude.com/docs), or the [pi](https://pi.dev) coding agent with OpenAI models (ChatGPT subscription or API key), in an isolated rootless Podman container that can reach only:

- the model API (Anthropic for Claude Code; OpenAI for pi),
- MCP servers for **Grafana**, **Graylog**, **Prometheus** (via Grafana) and, optionally, **GitHub**.

No host credentials are mounted into the agent container, and all service tokens (Grafana, Graylog, GitHub) live only in sidecar containers that the agent cannot read. `git push` is done on the host.

## Architecture

```
                 ab-internal (podman --internal, no route to the outside)
 ┌──────────────┐     │
 │ ab-claude-*  │─────┼──► ab-egress (squid) ───► Anthropic hosts only
 │ repo mounted │     ├──► ab-mcp-grafana ──────► Grafana (+ Prometheus datasources)
 │ no secrets*  │     ├──► ab-mcp-graylog ──────► Graylog /api/mcp
 └──────────────┘     │    (nginx, injects auth)
                      └──► ab-mcp-github ───► ab-mcp-github-srv ──► api.github.com
                           (nginx, caller auth,   (github-mcp-server,
                            injects PAT)           ab-egress only)
```

| Container | Networks | Holds secrets | Purpose |
|---|---|---|---|
| `ab-claude-<pid>` | `ab-internal` | Claude OAuth token only | Claude Code session, one per run |
| `ab-egress` | `ab-internal`, `ab-egress` | none | Squid forward proxy with a domain allowlist |
| `ab-mcp-grafana` | `ab-internal`, `ab-egress` | Grafana service account token | Official `grafana/mcp-grafana`, streamable HTTP on `:8000/mcp`, bearer-token caller auth, Host allowlist, `--disable-write`, usage stats off |
| `ab-mcp-graylog` | `ab-internal`, `ab-egress` | Graylog API token | nginx reverse proxy to Graylog's built-in MCP endpoint, adds `Authorization` |
| `ab-mcp-github` | `ab-internal`, `ab-egress` | GitHub PAT | nginx: checks the caller token, injects the PAT, pins toolsets and lockdown mode. Optional |
| `ab-llm-openai` | `ab-internal`, `ab-egress` | OpenAI API key | nginx: checks the caller token, injects the API key, forwards to `api.openai.com` with certificate verification. Only for pi in API-key mode |
| `ab-mcp-github-srv` | `ab-egress` **only** | none | Official `github-mcp-server` in HTTP mode. Not reachable from the agent. Optional |

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

## Security model

**What is isolated**

- **Network.** The agent sits on a `--internal` network. Its only way out is the squid proxy, which allows the three Anthropic hosts Claude Code needs (`api.anthropic.com`, `platform.claude.com`, `claude.ai`) and package sources for Python (`pypi.org`, `files.pythonhosted.org`) and Go (`proxy.golang.org`, `sum.golang.org`), each removable. Everything else, GitHub included, gets a 403.
- **claude.ai connectors.** `ENABLE_CLAUDEAI_MCP_SERVERS=false` stops Claude Code from loading MCP connectors configured in your claude.ai account (mail, chat, drives, ...). Only the MCP servers registered inside the box are available.
- **Credentials.** Nothing from the host environment, `~/.ssh`, `~/.aws`, `~/.kube` etc. is visible. Grafana, Graylog and GitHub tokens exist only in their sidecars, provided as Podman secrets.
- **The agent's own binary.** Claude Code is installed into `ab-claude-tools` by a separate short-lived container and mounted read-only, so the agent cannot modify its own executable.
- **Host-side git execution.** `.git/hooks` and `.git/config` are mounted read-only. A writable copy would let the agent plant a hook or `core.fsmonitor` that runs **on the host** the next time you run `git commit` or `git status`.
- **Process hardening.** `--cap-drop=ALL`, `no-new-privileges`, rootless Podman.

**What is NOT isolated**

- The repository is mounted read-write. The agent can change any file in it. Review diffs before running anything from the repo on the host (`Makefile`, scripts, `.envrc`, CI config, editor tasks).
- MCP tools act with the permissions of their service accounts. **Isolation does not limit what the tokens can do**, so make them read-only (see step 2).
- Squid filters by hostname and does not inspect TLS. A broad allowlist entry (e.g. a whole git hosting service) is a potential exfiltration path.
- "No credentials in the box" stops the agent from using **your** accounts, not someone else's. Every allowlisted API that accepts writes with a bearer token (`api.anthropic.com`, `api.openai.com`, and `github.com` if you enable it) could be used with a token planted through prompt injection to upload data to an attacker's account. Keep the allowlist to what you actually use.

## Requirements

- Linux with rootless Podman **4.x or newer** and the **netavark** network backend
  ```bash
  podman --version
  podman info --format '{{.Host.NetworkBackend}}'   # must print: netavark
  ```
- Network access from the host to Grafana and Graylog
- **Graylog 7.0+** for the built-in MCP endpoint. It is marked experimental by Graylog.
- A Claude subscription or Anthropic account for `claude setup-token`

## Files

| File | Purpose |
|---|---|
| `run.sh` | Entry point: networks, image, updates, sidecars, agent session |
| `config.env.example` | Settings template; copy to `config.env` (ignored by git) |
| `pi.sh` | Same as `run.sh`, with pi as the agent (`AB_AGENT=pi`) |
| `pi/models.json`, `pi/mcp.json` | pi configuration, mounted read-only: model endpoint and MCP servers |
| `pi/extensions/` | pi extensions you choose to allow, mounted read-only (empty by default) |
| `llm-openai.conf.template` | nginx config for the OpenAI sidecar: caller auth, API key injection |
| `Containerfile` | Base image: node, git, ripgrep, uv with preinstalled Python versions, Go, golangci-lint, graphify |
| `squid.conf` | Egress allowlist |
| `graylog-mcp.conf.template` | nginx config that injects the Graylog auth header |
| `github-mcp.conf.template` | nginx config for GitHub: caller auth, PAT injection, pinned toolsets |
| `skills/` | Optional. Personal skills, mounted read-only into the agent |
| `migrate-from-claude-box.sh` | One-off: move a claude-box setup (`cc-*` resources) to agentbox |
| `sync-skills.sh` | Host-side: vendor a skills repository into `skills/` (flattened) |
| `vendor/` | Created by `sync-skills.sh`: clones of vendored skills repositories |

## First-time setup

### 1. Install and configure

```bash
git clone <this repo> ~/agentbox   # or copy the files
cd ~/agentbox
chmod +x run.sh
```

Set your endpoints in `config.env` (base URLs only, without `/api` or `/api/mcp`; trailing parts are stripped anyway):

```bash
cp config.env.example config.env
$EDITOR config.env
```

`config.env` is parsed, not executed, accepts only known keys, and survives updates of `run.sh`. Environment variables override it, and `AB_CONFIG=/path/to/file` points to a different file, e.g. one per environment. Without `GRAFANA_URL` and `GRAYLOG_URL` the script stops with an error.

`squid.conf` is the egress allowlist. It allows the minimum the agents need: the Anthropic hosts Claude Code requires (see Claude Code's [network access requirements](https://code.claude.com/docs/en/network-config#network-access-requirements)), PyPI and the Go module proxy, and for pi with a ChatGPT subscription `auth.openai.com` and `chatgpt.com`. Each block is commented; remove what you don't use. Hosts that are deliberately **not** allowed:

| Host | Effect of blocking |
|---|---|
| `mcp-proxy.anthropic.com` | No claude.ai connectors (also disabled via env) |
| `registry.npmjs.org`, `github.com`, `storage.googleapis.com` | No plugin installs inside the session |
| `raw.githubusercontent.com` | `/release-notes` does not load |
| `code.claude.com`, `claude.com` | No built-in documentation lookups |
| `*.frame.claudeusercontent.com` | No artifact reads (also disabled via env) |
| Datadog intake hosts | No telemetry (also disabled via `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) |

### 2. Create read-only service accounts

- **Grafana:** Administration → Users and access → Service accounts → create an account with role **Viewer** → *Add service account token*.
- **Graylog:** create a dedicated user with a read-only role, then System → Users and Teams → *Tokens* → create an API token. Enable MCP in Graylog's settings.

### 3. Create networks, build the image, install Claude Code

```bash
podman network create --internal ab-internal
podman network create ab-egress
podman build -t localhost/agentbox -f Containerfile .

podman run --rm --network ab-egress --userns=keep-id:uid=1000,gid=1000 \
  -v ab-claude-tools:/opt/claude --entrypoint npm localhost/agentbox \
  install -g --prefix /opt/claude @anthropic-ai/claude-code@latest
```

`run.sh` does all of this automatically too, but it refuses to start until the secrets from step 5 exist, so do it manually the first time.

### 4. Get a Claude token

Run this inside the box, so Claude Code is not needed on the host:

```bash
podman run --rm -it --network ab-egress --userns=keep-id:uid=1000,gid=1000 \
  -v ab-claude-tools:/opt/claude:ro localhost/agentbox setup-token
```

Open the printed URL in a browser, sign in, and paste the code shown in the browser **back into this terminal**. `setup-token` then exchanges it and prints the long-lived token.

> **Code vs. token.** The browser shows a short-lived *authorization code*. That is not the token. The token is printed by `setup-token` in the terminal afterwards and always starts with `sk-ant-oat01-`. Only the token goes into the secret. Storing the code results in `401 Invalid bearer token`.
>
> `OAuth error: Request failed with status code 400` during this step means the code was rejected: it expired, was pasted incompletely, or was already used. Run `setup-token` again and paste the fresh code right away.

### 5. Create Podman secrets

`read -s` keeps tokens out of your shell history.

> **Run these commands one at a time.** Paste one line, press Enter, then paste only the token at the prompt. Pasting the whole block at once makes each `read` consume the next pasted command line as its input, and the secrets end up containing shell commands instead of tokens.

```bash
read -rsp 'Claude token: '  T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create claude_oauth -; echo
read -rsp 'Grafana token: ' T && printf '%s' "$T" | podman secret create grafana_sa -; echo
read -rsp 'Graylog token: ' T && printf '%s:token' "$T" | base64 -w0 | podman secret create graylog_basic -; echo
unset T
podman secret ls
```

The Graylog secret is `base64("<token>:token")`, the literal word `token` is the password, as Graylog expects.

### 6. Register the MCP servers

Arguments after the repo path are passed to `claude`, so this works from outside:

The Grafana sidecar requires a bearer token from its callers. `run.sh` generates it on the first run as the `grafana_mcp_caller` secret, so run `run.sh` once before this step. This token is not a Grafana credential: it only lets the caller talk to the sidecar, so storing it in Claude's config inside the box is fine.

```bash
TOK=$(podman run --rm --network none --secret grafana_mcp_caller,type=env,target=T \
  --entrypoint sh localhost/agentbox -c 'printf %s "$T"')
./run.sh ~/src/myrepo mcp add --scope user --transport http grafana http://ab-mcp-grafana:8000/mcp \
  --header "Authorization: Bearer $TOK"
unset TOK
./run.sh ~/src/myrepo mcp add --scope user --transport http graylog http://ab-mcp-graylog:8080/mcp
```

To re-register (e.g. after the caller secret was recreated), run `./run.sh ~/src/myrepo mcp remove --scope user grafana` first.

Registrations are stored in the `ab-claude-home` volume and apply to every repo.

There is no separate Prometheus server: `mcp-grafana` includes tools for querying Prometheus datasources configured in Grafana. If that is not enough, add another sidecar following the same pattern.

### 7. Verify

```bash
./run.sh ~/src/myrepo
```

Inside the session:

- `/mcp` shows `grafana` and `graylog` as connected.
- Ask Claude to run `curl -sI https://example.com`. Expected: **403** from squid.
- Ask Claude to run `env | grep -iE 'token|key|pass'`. Expected: only `CLAUDE_CODE_OAUTH_TOKEN`.
- Ask for the latest errors from Graylog and the `up` status of Prometheus targets to confirm the MCP servers reach their backends.

## GitHub (MCP)

Optional. When a `github_pat` secret exists, `run.sh` starts two extra sidecars and the agent gets GitHub through MCP: pull requests, issues, review comments, CI runs and logs, reading repository contents. **The token never enters the agent container**, and `github.com` stays out of the egress allowlist.

What the agent can **not** do: `git fetch`/`git push`, or change code on GitHub. Code goes through you:

1. the agent commits locally in the mounted repo;
2. you review the diff and `git push` from the host;
3. the agent opens the PR, reads CI results and review comments through MCP.

### How it is wired

- **`ab-mcp-github-srv`** runs the official `github-mcp-server` in HTTP mode. It holds no token and is attached to `ab-egress` only, so the agent cannot reach it directly.
- **`ab-mcp-github`** (nginx, `github-mcp.conf.template`) is the only entry point. It
  - rejects requests without the caller token (`github_mcp_caller`, generated automatically);
  - replaces the caller token with the PAT;
  - pins `X-MCP-Toolsets` to `GH_TOOLSETS` and `X-MCP-Lockdown: true`, and drops any `X-MCP-Readonly`, `X-MCP-Tools` or `X-MCP-Insiders` sent by the client;
  - always proxies to the server root, so the agent cannot switch to other server paths.

The agent can edit its own MCP registration in `ab-claude-home`, so server behaviour is enforced in nginx, not in the client config. **The real boundary is still the PAT's permissions.**

Default toolsets: `context,repos,issues,pull_requests,actions`. Override with `GH_TOOLSETS` and restart with `AB_RESTART=1`.

Lockdown mode hides content in public repositories from users without push access to them. It currently covers reading issues only, so content fetched from public repositories by other tools can still carry prompt injection.

### 1. Create a fine-grained personal access token

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

### 2. Store the token and start the sidecars

```bash
read -rsp 'GitHub token: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create github_pat -; echo; unset T
AB_RESTART=1 ./run.sh ~/src/myrepo -p "say ok"     # creates github_mcp_caller, starts the sidecars
```

### 3. Register the MCP server

```bash
TOK=$(podman run --rm --network none --secret github_mcp_caller,type=env,target=T \
  --entrypoint sh localhost/agentbox -c 'printf %s "$T"')
./run.sh ~/src/myrepo mcp add --scope user --transport http github http://ab-mcp-github:8080/mcp \
  --header "Authorization: Bearer $TOK"
unset TOK
./run.sh ~/src/myrepo mcp get github      # expect: Connected
```

### Disable

```bash
./run.sh ~/src/myrepo mcp remove --scope user github
podman rm -f ab-mcp-github ab-mcp-github-srv
podman secret rm github_pat github_mcp_caller
```

### GitHub read access (optional)

The GitHub MCP sidecar covers your own repositories. For **anonymous read access to public GitHub** (cloning a library to read its source, `uv` dependencies from git, raw files, release downloads), uncomment the GitHub block in `squid.conf` and run `AB_RESTART=1 ./run.sh`.

What it does and does not change:

- **No writes.** There is no GitHub token in the agent container, so it cannot push, open issues, comment or create gists. Your private repositories stay unreachable this way, too.
- **It cannot be limited to reads at the network level.** Squid sees only the host name of a `CONNECT`, not the HTTP method or path, so it allows any request to these hosts. Without credentials that is harmless for GitHub itself, but each allowed host is still a place the agent can send requests to.
- **Main risk is inbound.** Public repositories, issues and READMEs are arbitrary third-party text and code: a prompt injection source and a supply-chain source, like PyPI. Weigh this against what the agent can read in the box: your code, and whatever the MCP servers return, such as logs.

Leaving it off and asking the agent to read public repositories through the GitHub MCP tools (the PAT can read public repositories) is the more contained alternative.

## pi (OpenAI)

[pi](https://pi.dev) runs in the same box as Claude Code: same image, networks, squid, MCP sidecars, repo protections, Python and Go. Start it with `pi.sh` instead of `run.sh`; arguments work the same way.

> Do not use the Claude subscription token with pi. Anthropic permits subscription OAuth only in Claude Code and Claude.ai, not in third-party tools.

There are two ways to give pi OpenAI models. Both use pi's **OpenAI** provider (`openai/...` models); `run.sh` picks the mode by whether the `openai_api_key` secret exists.

| | ChatGPT subscription (default) | OpenAI API key |
|---|---|---|
| Sign-in | `/login` → OpenAI → *Sign in with ChatGPT*, once | `openai_api_key` Podman secret |
| Billing | Your ChatGPT plan | Per token, OpenAI platform |
| Credential in the agent container | **Yes**: `~/.pi/agent/auth.json` in `ab-pi-home`, incl. refresh token. Claude Code sessions cannot see it | **No**: only in the `ab-llm-openai` sidecar |
| Egress | `auth.openai.com`, `api.openai.com` via squid | none, through the sidecar |
| `pi/models.json` | not mounted | mounted: points the provider at the sidecar |

**Do not use "OpenAI Codex (legacy)".** It is pi's older ChatGPT integration: it talks to ChatGPT's internal Codex backend (`chatgpt.com/backend-api`), which is not a public API and can change without notice, and pi marks it legacy. *Sign in with ChatGPT* on the OpenAI provider gets a token issued for the public API (`api.openai.com`) and uses the same endpoint and request format as API-key access. Check `/model` for the models your plan offers there.

### Setup: ChatGPT subscription

1. Start pi in a repo: `cd ~/src/myrepo && ~/agentbox/pi.sh`. The first run installs pi into the `ab-pi-tools` volume.
2. Run `/login`, choose **OpenAI**, then **Sign in with ChatGPT**. Open the shown URL in your browser on the host and approve.
3. The browser is then redirected to `http://127.0.0.1:1455/auth/callback?...` and shows a connection error: the callback listener runs inside the container, not on your host. That is expected. **Copy the full URL from the address bar** and paste it into pi's prompt.
4. pi stores the tokens in `~/.pi/agent/auth.json` in `ab-pi-home` and refreshes them itself; this is needed once per box, not per repo.
5. Pick an `openai/...` model with `/model` and press `Ctrl+S` to make it the default.
6. Check MCP with `/mcp`. If you do not use the GitHub MCP sidecar, remove the `github` entry from `pi/mcp.json`.

**The token is readable by the agent**, as the Claude OAuth token is for Claude Code: pi has to write and refresh it, so it cannot be hidden in a sidecar. To revoke it, run `/logout` in pi and end the session in your ChatGPT account's security settings.

`auth.openai.com` and `api.openai.com` are in `squid.conf` for this mode. Squid is shared, so Claude Code sessions can reach them too; remove the two lines if you use pi with an API key or not at all. `chatgpt.com` is only needed for the legacy provider and is commented out.

### Setup: OpenAI API key

`pi/models.json` points pi's built-in `openai` provider at the `ab-llm-openai` sidecar, which swaps a caller token for the real key and forwards to `api.openai.com` with certificate verification. The key never enters the agent container.

1. Create a project API key with a spending limit in the OpenAI platform.
2. Store it (one command at a time):
   ```bash
   read -rsp 'OpenAI API key: ' T && printf '%s' "$T" | tr -d '[:space:]' | podman secret create openai_api_key -; echo; unset T
   ```
3. `~/agentbox/pi.sh`: creates `llm_openai_caller`, starts the sidecar. Pick an `openai/...` model with `/model`. No `/login`.

### What pi gets from the host, read-only

| Host file | In the container | Purpose |
|---|---|---|
| `pi/models.json` | `~/.pi/agent/models.json` | OpenAI API endpoint = the sidecar (API-key mode) |
| `pi/mcp.json` | `~/.pi/agent/mcp.json` | Grafana, Graylog, GitHub MCP sidecars, with caller tokens from env |
| `skills/` | `~/.pi/agent/skills` | Same personal skills as Claude Code |
| `pi/extensions/` | `~/.pi/agent/extensions` | Extensions you allow (empty by default) |

Read-only matters here: pi executes extensions it finds in its agent directory and reads its model endpoint and MCP servers from these files. If the agent could write them, it could redirect its own model traffic, add servers or plant code that persists across sessions. Sessions, `settings.json` and `auth.json` stay writable in `ab-pi-home`.

pi runs with `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1` and `PI_TELEMETRY=0`: no model catalog refresh, version check or telemetry.

### Extensions and skills

pi's MCP support is built in, no extension needed. `pi install ...` does not work inside the box (no npm access) and would write to the agent directory anyway. To allow an extension, read it, then copy it into `pi/extensions/` on the host. Skills come from `skills/`, the same directory Claude Code uses, so `sync-skills.sh` covers both agents. Skills written for Claude Code may rely on Claude-specific features such as subagents and work less well in pi.

#### Migrating from claude-box

This project was called claude-box and used `cc-` prefixed resources. `migrate-from-claude-box.sh` moves an existing setup over, see [Migration from claude-box](#migration-from-claude-box).

## Updates

pi updates like Claude Code: automatically at most every 6 hours, into its own `ab-pi-tools` volume, by a short-lived container with internet access. `AB_UPDATE=1 ./pi.sh` forces it.

## Daily usage

```
run.sh [repo-dir] [claude args...]
```

If the first argument is an existing directory, it is mounted as the repo. Otherwise the **current directory** is used and all arguments go to `claude`. The script prints which directory it mounts, and refuses to mount the agentbox directory itself.

```bash
cd ~/src/myrepo && ~/agentbox/run.sh             # current directory
~/agentbox/run.sh ~/src/myrepo                   # explicit repo
~/agentbox/run.sh --dangerously-skip-permissions # current directory + claude flags
~/agentbox/run.sh ~/src/myrepo -p "say ok"       # explicit repo + claude args
```

Relative paths are resolved against **your** current directory, not the script's.

One caveat: a first argument that happens to be the name of a directory in your current directory is taken as the repo. For a claude subcommand with such a name, pass the repo explicitly: `run.sh . <subcommand>`.

Convenient alias:

```bash
alias cbox=~/agentbox/run.sh
# cbox                  -> current directory
# cbox ~/src/other      -> that repo
# cbox mcp list         -> current directory, claude subcommand
```

Several sessions can run in parallel. Each gets its own `ab-claude-<pid>` container, and they share the sidecars.

**About `--dangerously-skip-permissions`.** Inside this box it is a reasonable choice: the worst case is modified files in the repo (recoverable via git), read access to Grafana and Graylog within Viewer rights, and requests to allowlisted hosts. It is only reasonable if the service accounts are really read-only.

## Skills

Claude Code picks up skills from two places, and both work in the box without network access:

| Kind | Location | How it gets into the box |
|---|---|---|
| Project skills | `<repo>/.claude/skills/<name>/SKILL.md` | Nothing to do: the repo is mounted |
| Personal skills | `~/.claude/skills/<name>/SKILL.md` | Put them in `skills/` next to `run.sh`; it is mounted **read-only** over `~/.claude/skills` |

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

**Plugins and marketplaces** (`/plugin install ...`) and `npx skills add` do not work in the box: they download from `github.com` and `registry.npmjs.org`, which are blocked. Use `sync-skills.sh` on the host instead.

### Vendoring a skills repository: `sync-skills.sh`

Runs on the **host**. It clones the repository into `vendor/<owner>__<repo>/`, finds every directory with a `SKILL.md` at any depth and copies it **flat** into `skills/<name>/`, because Claude Code only looks one level deep. It records what it installed in `skills/.vendored-<owner>__<repo>`, so later runs remove skills dropped upstream or deselected, and it never overwrites a skill it did not install.

```bash
./sync-skills.sh <git-url> [ref]            # ref: branch, tag or commit; default: remote default branch
SKILLS_ONLY=a,b,c ./sync-skills.sh <git-url> # install a subset
```

Read what you vendor: skills are instructions the agent follows, and bundled scripts are executed. `git -C vendor/<owner>__<repo> log` shows what changed since your last sync. Pinning a commit and updating deliberately is safer than following the default branch.

#### Example: mattpocock/skills

The repository groups skills by category (`engineering`, `productivity`, `misc`, `in-progress`). A sensible subset is engineering and productivity, without the unfinished `in-progress` ones:

```bash
SKILLS_ONLY=ask-matt,code-review,codebase-design,diagnosing-bugs,domain-modeling,grill-with-docs,implement,implement-spec,improve-codebase-architecture,pr,prototype,retro,setup-matt-pocock-skills,tdd,to-spec,to-tickets,triage,wayfinder,wizard,grill-me,grilling,handoff,teach,to-questionnaire,wait-what,writing-for-agents \
  ./sync-skills.sh https://github.com/mattpocock/skills
```

Then in a session, once per repo: `/setup-matt-pocock-skills`. Things to know for this box:

- **Issue tracker.** The GitHub option tells the agent to use the `gh` CLI, which the box does not have. Either pick **local markdown** during setup, or pick GitHub and afterwards edit the generated issue-tracker document in your repo to say "use the github MCP tools" instead of `gh` commands (requires [GitHub (MCP)](#github-mcp)). The other skills read that document, so the change applies everywhere.
- **`pr`** creates pull requests. It needs GitHub MCP, and the branch must already be pushed from the host.
- **`research`** relies on fetching web pages. `WebFetch` to arbitrary sites is blocked by squid, so expect it to be of limited use in the box.

## Python

The image has [uv](https://docs.astral.sh/uv/) and preinstalled interpreters, so Python projects work in the box without any setup.

| | |
|---|---|
| Interpreters | `PYTHON_VERSIONS` in `Containerfile` (default `3.12 3.13`), installed at build time into `/opt/uv-python`, on `PATH` as `python3.12`, `python3.13`. The system `python3` is Debian's 3.11 |
| Packages | `uv add`, `uv sync`, `uv run`, `pip` inside a venv: PyPI is in the egress allowlist |
| Virtualenv | Per repo, **outside the repo**, in `ab-cache` (`~/.cache/venvs/<repo>-<hash>`), via `UV_PROJECT_ENVIRONMENT`. Shared by both agents |
| uv cache | `ab-cache`, persists across sessions, shared by both agents |

Interpreters cannot be downloaded at runtime (`UV_PYTHON_DOWNLOADS=never`; their source, GitHub, is blocked anyway). For another version, add it to `PYTHON_VERSIONS` and run `AB_UPGRADE=1 ./run.sh`.

**Why the venv is outside the repo.** A `.venv` created in the container points at `/opt/uv-python/...`, which does not exist on the host, and a host `.venv` points at host paths. Sharing one directory breaks whichever side used it last. With `UV_PROJECT_ENVIRONMENT`, `uv` in the box never touches `<repo>/.venv`, so you can keep using your host venv in parallel. Projects that do not use uv (plain `python -m venv .venv`) are not covered by this; create such venvs outside the repo too, e.g. under `~/.venvs`.

**PyPI is a trade-off.** It lets the agent install packages on its own, which is convenient, but it is also how a malicious or typo-squatted package would get into the box. The damage stays inside the box (no host credentials, no other egress), but the code it writes ends up in your repo. Review `pyproject.toml` / `uv.lock` changes in your diffs. To make dependency changes go through you, remove the two PyPI lines from `squid.conf` and `AB_RESTART=1 ./run.sh`; then run `uv sync` once from a container with internet access, or add packages on the host.

## Go

The image has the Go toolchain and [golangci-lint](https://golangci-lint.run), both from the official release archives and verified against their published SHA-256 checksums.

| | |
|---|---|
| Versions | `GO_VERSION`, `GOLANGCI_LINT_VERSION` in `Containerfile`. Empty (default) = latest release at build time, so every `AB_UPGRADE` brings the newest; set them to pin. The build log prints what was installed |
| Modules | `proxy.golang.org` and `sum.golang.org` are in the egress allowlist, so `go mod download`, `go get`, `go build` work |
| Caches | Module cache in `ab-go` (`~/go`), build cache in `ab-cache`, both persist and are shared by both agents |
| Tools | `go install pkg@version` lands in `~/go/bin`, which is on `PATH` |
| Toolchain switching | Off: `GOTOOLCHAIN=local`. A `go.mod` that needs a newer Go fails with a clear error instead of downloading a toolchain; rebuild with `AB_UPGRADE=1` |

Things to know:

- **Private modules** (`GOPRIVATE`, your organisation's repositories) are fetched directly from the git host with credentials, which the box does not have. Use `go mod vendor` on the host and build with `-mod=vendor` in the box.
- **golangci-lint and the Go version.** golangci-lint must be built with a Go version at least as new as the one your `go.mod` targets. With both versions left on "latest" they stay in step; if you pin one, pin the other to match.
- **Same trade-off as PyPI.** The module proxy lets the agent add dependencies on its own. `sum.golang.org` guarantees you get the same code as everyone else for a given version, not that the code is benign. Review `go.mod` / `go.sum` changes; to keep dependency changes on the host, remove the two Go lines from `squid.conf`.
- `govulncheck` needs `vuln.go.dev`, which is not allowlisted.

## Graphify

[graphify](https://github.com/Graphify-Labs/graphify) turns the repo into a queryable knowledge graph. It is a Python CLI plus a `/graphify` skill that calls it, so unlike plain skills it has to be **in the image**: the agent cannot install it from PyPI.

The `Containerfile` installs it into `/opt/graphify` and exposes it as `/usr/local/bin/graphify`. The version is pinned with `GRAPHIFY_VERSION`; optional extras (e.g. `[sql,terraform]` for SQL schemas and Terraform) via `GRAPHIFY_EXTRAS`. To change either:

```bash
podman rmi localhost/agentbox
podman build -t localhost/agentbox --build-arg GRAPHIFY_EXTRAS='[terraform]' -f Containerfile .
```

### Enable it in a repo

Inside a session (or `./run.sh ~/src/myrepo` and ask the agent to run them):

```bash
graphify install --project      # skill into .claude/skills/graphify/, plus CLAUDE.md
graphify claude install         # PreToolUse hooks in .claude/settings.json: nudge the agent to query the graph before grep/read
```

Then `/graphify .` builds the graph into `graphify-out/`.

Project scope is deliberate: `~/.claude/skills` is read-only in the box, and the skill should match the CLI version in the image. Add `graphify-out/` to `.gitignore`.

### What works in the box

- **Code graph:** fully local (tree-sitter), no network. Verified offline with `graphify extract . --code-only`.
- **Docs, PDFs, images:** inside the `/graphify` skill the semantic pass uses the Claude session itself, so it works on your subscription. Headless `graphify extract` on docs needs an API key and does not work in the box; use `--code-only` there.
- **Queries:** `graphify query`, `path`, `explain` on `graph.json`.

What does **not** work, by design: `/graphify add <url>`, `graphify clone` and video/URL transcription (no internet), `graphify prs` (no `gh`), and `graphify hook install` (`.git/hooks` is read-only, so graphify git hooks can never run code on the host). Ask the agent to run `graphify update .` after larger changes instead.

### Things to watch

- **The hooks contain an absolute path.** `graphify claude install` writes `/usr/local/bin/graphify hook-guard ...` into `.claude/settings.json`. If you also open this repo with Claude Code on the host, those hooks run **on the host** and need graphify at that same path there; otherwise they fail.
- **`.claude/settings.json` and `CLAUDE.md` are shared if committed.** Hooks in a committed `settings.json` run for every colleague who opens the repo with Claude Code. Decide deliberately whether to commit them, or keep them out of git with `.git/info/exclude` on the host.
- graphify creates `.claude/settings.json.graphify-bak` when it edits settings; don't commit it.
- The query log is turned off in the image (`GRAPHIFY_QUERY_LOG_DISABLE=1`).

## Updates

| What | Updates how | Command |
|---|---|---|
| Claude Code, pi | **Automatically**, at most every 6 hours, in a separate short-lived container, each into its own volume | `AB_UPDATE=1 ./run.sh` / `AB_UPDATE=1 ./pi.sh` to force |
| Sidecar images (`mcp-grafana`, `github-mcp-server`, nginx, squid) | Only on request: podman never re-pulls an image it already has | `AB_UPGRADE=1 ./run.sh` |
| Base image (Debian packages, git, Python) | Only on request: a cached build never re-runs `apt-get` | `AB_UPGRADE=1 ./run.sh` |
| graphify | Pinned in `Containerfile` | Bump `GRAPHIFY_VERSION`, then `AB_UPGRADE=1 ./run.sh` |
| Go, golangci-lint | Latest at build time unless pinned in `Containerfile` | `AB_UPGRADE=1 ./run.sh` |
| uv, Python interpreters | Pinned in `Containerfile` | Bump `UV_VERSION` / edit `PYTHON_VERSIONS`, then `AB_UPGRADE=1 ./run.sh`. Which patch release of each version gets installed is decided by the uv version, so bump `UV_VERSION` to get newer patch releases |
| Vendored skills | Only on request | `./sync-skills.sh <git-url> [ref]` |
| Tokens (Claude, Grafana, Graylog, GitHub) | Expire on their own schedule | Recreate the Podman secret, then `AB_RESTART=1 ./run.sh` |

`AB_UPGRADE=1` does everything in one go: pulls the sidecar images, rebuilds the base image from scratch (`--pull --no-cache`), updates Claude Code and recreates the sidecars. It does not touch volumes, secrets or MCP registrations. Running it every week or two is a reasonable rhythm; it takes a few minutes because of the full rebuild.

### Claude Code

`run.sh` updates it at most once every 6 hours: a container with internet access but without the repo or the agent runs `npm install -g @anthropic-ai/claude-code@latest` into `ab-claude-tools`.

```bash
AB_UPDATE=1 ./run.sh                # force an update now
AB_UPDATE_EVERY=86400 ./run.sh      # change the interval (seconds)
```

To pin a version, change `@latest` in `run.sh` to `@x.y.z` and run with `AB_UPDATE=1`.

### graphify

Check the latest release and what changed before bumping:

```bash
curl -s https://pypi.org/pypi/graphifyy/json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])'
```

Set `GRAPHIFY_VERSION` in `Containerfile`, then `AB_UPGRADE=1 ./run.sh`. The project-scoped skills in your repos (`.claude/skills/graphify/`) are refreshed by graphify itself on the next `graphify` command; a locally edited `SKILL.md` is kept as `SKILL.md.bak`. Commit the refreshed files if you track them.

### Pinning sidecar images

The sidecars use floating tags (`:latest`, `:alpine`), so an upgrade can change their behaviour, as happened with mcp-grafana's caller-auth and Host checks. To control that, pin tags in the `IMG_*` variables at the top of `run.sh` and bump them deliberately.

## Configuration reference

| Variable | Default | Meaning |
|---|---|---|
| `AB_CONFIG` | `<script dir>/config.env` | Settings file. All variables in this table except `AB_AGENT`, `AB_UPDATE`, `AB_RESTART`, `AB_UPGRADE` can be set there |
| `GRAFANA_URL` | none, required | Grafana base URL |
| `GRAYLOG_URL` | none, required | Graylog base URL |
| `AB_UPDATE` | unset | `1` forces a Claude Code update |
| `AB_UPDATE_EVERY` | `21600` | Seconds between automatic updates |
| `GH_TOOLSETS` | `context,repos,issues,pull_requests,actions` | GitHub MCP toolsets, enforced by nginx |
| `AB_SKILLS_DIR` | `<script dir>/skills` | Personal skills directory, mounted read-only |
| `AB_AGENT` | `claude` | `pi` runs pi instead of Claude Code (what `pi.sh` sets) |
| `AB_UPGRADE` | unset | `1` pulls sidecar images, rebuilds the base image, updates Claude Code, recreates sidecars |
| `AB_RESTART` | unset | `1` recreates sidecars, needed after changing URLs, toolsets, `squid.conf` or the nginx templates |

Sidecars are started once and reused. After changing their configuration:

```bash
AB_RESTART=1 ./run.sh .
```

## Troubleshooting

```bash
podman logs ab-mcp-grafana        # Grafana auth or URL errors
podman logs ab-mcp-graylog        # 401: bad token, 404: MCP not enabled in Graylog
podman exec ab-egress tail -f /var/log/squid/access.log | grep DENIED   # blocked hosts
podman ps --filter name=ab-       # what is running
podman logs ab-mcp-github         # 401: caller token mismatch, re-register (GitHub, step 3)
podman logs ab-mcp-github-srv     # GitHub API errors
podman stop ab-egress ab-mcp-grafana ab-mcp-graylog ab-mcp-github ab-mcp-github-srv   # stop sidecars
```

| Symptom | Likely cause / fix |
|---|---|
| `missing podman secrets` | Step 5 not done. |
| Claude shows the login picker or says it is not logged in | See [Token not picked up](#token-not-picked-up). |
| `Unable to connect to Anthropic services` / `ERR_PROXY_TUNNEL` | Squid blocked a required host. The error names it; check the squid log for `DENIED`, add the host to `squid.conf`, then `AB_RESTART=1`. |
| Build or test commands fail to download dependencies | The package registry for your language is not in the allowlist. PyPI is allowed; add others deliberately, each one widens egress. |
| `go: go.mod requires go >= 1.X (running go 1.Y; GOTOOLCHAIN=local)` | The image's Go is older than the project needs. `AB_UPGRADE=1 ./run.sh` (or raise a pinned `GO_VERSION`). |
| `go` fails to fetch a module with a git or 410/404 error | Private module, or a module not on the public proxy. Vendor it on the host (`go mod vendor`). If the squid log shows `DENIED` for another host, the proxy redirected there; add it deliberately. |
| pi (API key): `OpenAI API error (401)` | Either the API key in `openai_api_key` is invalid, or the sidecar rejected the caller token: `podman logs ab-llm-openai` shows a 401 without an upstream request. If `llm_openai_caller` was recreated, `AB_RESTART=1 ./pi.sh`. |
| pi (subscription): sign-in or requests fail with `ERR_PROXY_TUNNEL` / 403 | `auth.openai.com` or `api.openai.com` missing in `squid.conf`, or squid not restarted: `AB_RESTART=1 ./pi.sh`. The squid log shows the denied host. |
| pi (subscription): browser shows "can't connect to 127.0.0.1:1455" after approving | Expected, the callback listener is inside the container. Copy the full URL from the address bar and paste it into pi. |
| pi (subscription): requests go to `ab-llm-openai` and fail | `pi/models.json` is mounted only when the `openai_api_key` secret exists. If you switched from API key to subscription, `podman secret rm openai_api_key`. |
| pi (subscription): worked before, now fails after an update | Update pi (`AB_UPDATE=1 ./pi.sh`). If you are on the legacy "OpenAI Codex" provider, switch to OpenAI → Sign in with ChatGPT. |
| pi: MCP server `failed` in `/mcp` | Same checks as for Claude Code: sidecar logs. For `github`, the GitHub MCP sidecar is optional; remove the entry from `pi/mcp.json` if you don't use it. |
| `uv` says a Python version is not available and downloads are set to `never` | That version is not baked into the image. Add it to `PYTHON_VERSIONS` in `Containerfile` and `AB_UPGRADE=1 ./run.sh`. |
| Sidecar can't resolve Grafana/Graylog | Internal DNS not visible to containers. Add `--dns <server>` or `--add-host` to the sidecar in `run.sh`. |
| `/mcp` shows a server as failed | Check `podman logs` of the sidecar. If logs are clean, add `ab-mcp-grafana` and `ab-mcp-graylog` to `squid.conf` in case Claude Code ignores `NO_PROXY`. |
| `podman logs ab-mcp-graylog` shows `POST /mcp ... 405 59` | The 59-byte body is Graylog's own `HTTP 405 Method Not Allowed` API error, so nginx works but Graylog has no MCP endpoint there. Enable MCP in System → Configurations → MCP, and check the Graylog version is 7.0+. |
| `mcp get grafana` shows `403 ... forbidden: host not allowed` | mcp-grafana validates the `Host` header against `--allowed-hosts`. It must include the name Claude uses (`ab-mcp-grafana:8000`). Recreate with `AB_RESTART=1`. |
| nginx sidecar exits on start | nginx resolves `GRAYLOG_URL` at startup. Fix DNS, or use an IP and check TLS/SNI. |
| `mcp get github` shows 401 | The caller token in Claude's registration does not match `github_mcp_caller`. Re-register (GitHub, step 3). |
| `mcp get github` shows 502 | nginx cannot reach `ab-mcp-github-srv`: check `podman ps` and its logs. If that container was restarted on its own, restart both with `AB_RESTART=1` (nginx caches its IP). |
| GitHub tools fail with 403 / 404 | The PAT lacks the permission, the repository is not selected in it, or an org-owned token is pending approval. Writes to code are expected to fail: Contents is read-only. |
| `git fetch` / `git push` fail inside the box | Expected: GitHub is not reachable from the agent. Run them on the host. |
| `git push -u`, `git remote add` fail | Expected: `.git/config` is read-only. Run these on the host. |
| Git does not work at all inside the box | The repo is a worktree or submodule (`.git` is a file). Its git dir is outside the mount. Run the box on the main checkout. |
| Write errors under `/opt/claude` | Claude Code needs to write to its install dir. Remove `:ro` from the `ab-claude-tools` mount (you lose binary tamper protection). |

## Token not picked up

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
./run.sh . -p "say ok"
```

- Works here but not interactively: an onboarding problem. Check `podman run --rm -v ab-claude-home:/h --entrypoint cat localhost/agentbox /h/.claude.json` for `"hasCompletedOnboarding": true`.
- Fails here too: the token is invalid or expired. Create a new one (setup step 4) and replace the secret.

**3. Stale login state in `ab-claude-home`.** If you once ran `/login` inside the box, stored credentials can take precedence. Run `/logout` in a session, or remove `/home/node/.claude/.credentials.json` from the volume.

## Not yet verified

These parts are assembled from documentation and tests against fake upstreams, but have not been run end to end:

- pi through the OpenAI sidecar against the real OpenAI API. The chain pi → nginx (caller check, key injection) → upstream was tested with a fake upstream.
- pi's *Sign in with ChatGPT* through squid with the pasted callback URL, and token refresh with `PI_OFFLINE=1` set.

- `github-mcp-server http` listening on all interfaces inside its container (nginx connects to it over the `ab-egress` network). If it binds to localhost only, nginx returns 502.
- github-mcp-server honouring `X-MCP-Toolsets` and `X-MCP-Lockdown` as set by nginx.

## Migration from claude-box

Run once, on the host, from the agentbox directory, with no agent sessions running:

```bash
./migrate-from-claude-box.sh
```

It:

1. removes the old sidecar containers (`cc-egress`, `cc-mcp-*`, `cc-llm-openai`) and networks (`cc-internal`, `cc-egress`);
2. copies the volumes: `cc-home` → `ab-claude-home`, `pi-home` → `ab-pi-home`, `cc-cache` → `ab-cache`, `cc-go` → `ab-go`. Pi state, caches and venvs that an older version left in `cc-home` are dropped from Claude's new home;
3. rewrites the MCP URLs in Claude Code's registrations (`http://cc-mcp-…` → `http://ab-mcp-…`); pi's are in `pi/mcp.json`, already updated;
4. copies the secret `cc_oauth` to `claude_oauth`. All other secret names are unchanged.

The tools volumes are not copied: the next `run.sh` / `pi.sh` installs the agents fresh into `ab-claude-tools` and `ab-pi-tools`, and builds the image as `localhost/agentbox`.

Environment variables were renamed from `CC_*` to `AB_*` (`AB_UPDATE`, `AB_RESTART`, `AB_UPGRADE`, ...); update aliases and scripts that set them.

The old volumes, image and secret are kept until you remove them. Once everything works:

```bash
podman volume rm cc-home pi-home cc-tools pi-tools cc-cache cc-go
podman rmi localhost/claude-box
podman secret rm cc_oauth
```

