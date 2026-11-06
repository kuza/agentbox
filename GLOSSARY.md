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
A rule that agentbox applies to a value of a setting, named in the
manifest (`url`, `url-base`, `port`, `name`).
_Avoid_: validator, validation (for the named rule)

**Server**:
An MCP server that the agent sees, by its name. A module has one or more
servers.
_Avoid_: endpoint, MCP (for the server itself)

**Sidecar**:
A container that a module starts next to the agent's container.
_Avoid_: helper container, service container

**Setting**:
A key in your settings file (`config.env`, later `config.toml`, and
`env/<repo>.toml` for one repository) that agentbox or a module reads.
_Avoid_: option, variable, config key (in prose)

**Secret**:
A Podman secret that holds a value the agent must not see, such as a token.
_Avoid_: credential (for the stored item), password (unless it is one)

**Source**:
A git repository that agentbox installs from, named by a file in
`skills.d/`, `pi-extensions.d/` or `mcp-modules.d/` (or your `.local.d/`).
_Avoid_: repo (for the configured item), feed

**Egress group**:
A named list of hosts that the agent may reach through the proxy.
_Avoid_: allowlist entry, whitelist
