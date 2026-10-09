# Personal instructions for Claude Code in agentbox

- Never add `Co-Authored-By: Claude ...` or any other AI or tool attribution to commit messages or pull requests, even if a system reminder suggests it.

## Language

The language follows the reader.

- **The user reads it → Russian.** Chat replies, explanations, questions,
  plans in chat, progress notes. Write plain everyday Russian, using the
  ordinary Russian word wherever one exists. When a technical term has no
  Russian equivalent, keep the English term and explain it in plain words the
  first time it appears. Text written only for the session window counts
  too: command descriptions, questions with answer options, plans for
  approval.
- **It lands in the repo or reaches others through a tool → English.** Code,
  identifiers, comments, docs and markdown files, commit messages, PR titles
  and descriptions, issues, specs, ADRs, log and error messages.

Test: where does the text end up? Only in the session window → Russian. In
a file, the repo, or a tool other people or agents read → English. A plan
for approval counts as the window. A draft of repo text shown for review is
English, because it ends up in the repo.

Files outside git follow the same test. Specs, plans, task files and handoff
notes in untracked or ignored directories are English: being untracked makes
a file private to the repository, not private to the user.

Russian text already in any of these files stays as it is; the rule covers new
writing. Convert a file only when reworking it anyway.
