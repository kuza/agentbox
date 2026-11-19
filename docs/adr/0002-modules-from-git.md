---
status: accepted
---

# Modules from git: a consent for the content, and own prefixes

A module from git can come from another person. Its `mcp.sh` runs on the
host with your rights, and its manifest can give the agent servers and
egress hosts. Thus agentbox activates nothing of a module from git until
you give a consent. The consent is for one content: the URL, the
`subdir` and the git tree id of the `subdir`. The settings of a module from
git start with `GITMOD_<MODULE>__`, and its secrets start with
`git_<module>_`.

## Considered Options

- **A consent for a commit.** One commit holds all modules of a
  repository. A consent for it also allows a `mcp.sh` in another `subdir`
  that you did not see. Also, each commit in another part of the
  repository asks again.
- **A `runs_code = true` key in the source file, and a yes at the
  enable.** The key adds nothing to a consent for one content. A module in
  `AB_MCP` skips the yes at the enable.
- **No consent for a module without code.** Such a module adds servers,
  egress hosts and ports with no list that you see.
- **The prefix `GIT_<MODULE>_` for settings.** `GIT_*` names are
  variables of git: a module `ssh` with the setting `COMMAND` gives
  `GIT_SSH_COMMAND`, which git runs. Also, one prefix can contain
  another (`jira` with `CLOUD_URL`, and `jira-cloud` with `URL`). The
  double underscore of `GITMOD_<MODULE>__` stops both.
- **No prefix, refuse the names of other modules.** A later shared module
  can take the name, and a module from git then gets your value.

## Consequences

- The tree id protects the content only if the bytes on disk agree with
  it. agentbox writes the module files itself from the git objects, with
  no filters, and compares their ids after the yes.
- A new version waits in a pending directory. Nothing runs from it before
  the yes, and the old version stops before the new one moves into place.
- A module from git with the name of a shared module, or of a module in
  `mcp.local/`, leaves out both modules. Rename the source file to solve
  it. The prefixes follow the new name, so you store the secrets again.
- A change of the prefixes after the release changes your settings and
  secrets, so the prefixes stay.
