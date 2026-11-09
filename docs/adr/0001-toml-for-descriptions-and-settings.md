---
status: accepted
---

# TOML for descriptions and settings; flat TOML for settings

All files that describe something to agentbox use TOML: the module
manifests (`module.toml`), the skill sources, the pi extension sources
and the egress groups. Your settings move from `config.env` to a flat
`config.toml`, and the settings of one repository from `env/<repo>.conf`
to `env/<repo>.toml`: top-level `KEY = value` lines only, with arrays for
lists and no tables. Python 3.11 or newer on the host reads all of them with
`tomllib`. Bash only edits the lines of `config.toml` in `agentbox setup`.

The goals:

- one format for all files;
- files that a later Go core reads with no second migration;
- no more parsing of module code as text.

## Considered Options

- **JSON.** Each Python version has a JSON parser, so it would not need
  Python 3.11. But JSON has no comments, and you edit these files by hand.
- **YAML.** Python has no YAML parser in its standard library, so the
  host would need PyYAML. Implicit types (`no` as false, `1.10` as 1.1)
  and the meaning of indents are traps in files with ports, versions and
  names.
- **Full TOML for settings (tables such as `[github]`).** Bash cannot edit
  it and keep your comments and the order of the lines, and Go TOML
  libraries mostly lose comments when they write. A flat file is a set of
  lines that both can edit.
- **Keep `config.env` as `KEY=VALUE` until the move to Go.** That means two
  migrations of your file instead of one.
- **A TOML parser in bash, or `tomli` for Python 3.9 and 3.10.** An own
  parser gives a second behaviour next to `tomllib`. `tomli` is an install
  on the host too, and less visible than `python3.11`.

## Consequences

- The host needs Python 3.11 or newer, for a start and for
  `agentbox setup`. Both read the files, and both convert your old files
  one time. Ubuntu 22.04 and
  RHEL 9 need an extra package (`python3.11`). Without it, `update`,
  `rollback` and `uninstall` still work; a start or setup stops with the
  reason.
- The flat file has limits: `agentbox setup` does not change a key whose
  value has more than one line; an item of an array cannot hold a space or
  a comma; `false` is `0`. The files refuse floats, dates, tables, quoted
  keys, keys with a dot, multi-line strings and control characters in
  values.
- Bash gets `true` as `1`. For a list setting of agentbox (such as
  `AB_MCP`), bash gets the items joined with a space. For a module setting
  (such as `GH_TOOLSETS`), bash gets the items joined with a comma. Later,
  the module manifests (v0.2.x) will set the separator of each module
  setting.
- Keys of settings stay in uppercase, because environment variables of the
  same name override them. Keys of descriptions are in lowercase.
- The old module format (only `mcp.sh`) goes in v0.3.0. A module of yours
  in `mcp.local/` then needs a `module.toml`, written by hand with the
  README section "Converting a module". There is no conversion command:
  to read module code as text is the fragile part that this change
  removes. The old format goes, because two loaders need each fix twice.
- The old settings files stay until v0.3.0, so a rollback to v0.1.x
  works.
- The change comes in steps: settings and simple descriptions in v0.2.0;
  module manifests in v0.2.x; modules from git sources later; removal of
  the old formats in v0.3.0. The Go core comes after these steps.
