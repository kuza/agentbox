# agentbox

agentbox runs a coding agent in a rootless Podman container. The agent
reaches only the hosts and the MCP servers that you allow. These terms
name the parts that you configure.

## Language

**Module**:
A directory with a manifest that gives the agent one or more servers. You
enable a module by its name in `AB_MCP`.
_Avoid_: plugin, MCP module (when "module" is clear), integration

**Manifest**:
The `module.toml` of a module: its settings, secrets, servers and images,
as data.
_Avoid_: module config, descriptor

**Check**:
A rule for the value of a setting. A built-in check has a name that the
manifest gives; a module can add its own check in its code.
_Avoid_: validator, validation (for the named rule)

**Server**:
An MCP server that the agent sees, by its name. A module has one or more
servers.
_Avoid_: endpoint, MCP (for the server itself)

**Caller token**:
A random token that agentbox makes for a sidecar and gives to the agent.
The sidecar refuses a call without it.
_Avoid_: MCP token, bearer token, API key (for this token)

**Sidecar**:
A container that agentbox starts next to the agent's container: for a
module, or for agentbox itself (such as `ab-llm-openai`).
_Avoid_: helper container, service container

**Setting**:
A key in your settings files (`config.toml`, and `env/<repo>.toml` for one
repository) that agentbox or a module reads.
_Avoid_: option, variable, config key (in prose)

**Secret**:
A Podman secret that holds a value such as a token. agentbox gives the
agent only the secrets that it needs to work: its login token and the
caller tokens. The others stay in the sidecars.
_Avoid_: credential (for the stored item), password (unless it is one)

**Old file**:
A settings file of agentbox v0.1.x (`config.env`, `env/<repo>.conf`, a
`.conf` file in a `.local.d/` directory) that agentbox converts to TOML.
_Avoid_: legacy file, v1 file

**Old-format module**:
A module with an `mcp.sh` and no manifest. agentbox v0.3.0 and later do
not load it.
_Avoid_: legacy module, module of the old format

**Source**:
A git repository that agentbox installs from, named by a file in
`skills.d/` or `pi-extensions.d/` (or your `.local.d/`), or in your
`mcp-modules.local.d/`.
_Avoid_: repo (for the configured item), feed

**Consent**:
Your yes to one content of a module from git: its URL, its directory and
the git id of that directory. Until a consent matches the content,
agentbox activates nothing of that module.
_Avoid_: approval, trust, permission (for this yes)

**Egress group**:
A named list of hosts that the agent may reach through the proxy.
_Avoid_: allowlist entry, whitelist
