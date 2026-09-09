---
name: herdr-auto-title
description: Keep the Herdr tab that hosts this interactive coding agent titled with a short 3-6 word summary of what it is doing right now. Use whenever running inside Herdr (HERDR_ENV=1) - on every new user request, whenever the task, phase, or focus changes, and when the user asks to rename or stop renaming the tab. Not for controlling other panes, tabs, or agents; use the herdr skill for that.
license: MIT
compatibility: Requires the Herdr CLI (herdr 0.9+) in PATH, HERDR_ENV=1 in the calling pane, POSIX sh, and jq for the bundled script.
metadata:
  author: dan-myles
  version: "1.0"
---

# Herdr auto title

Give the tab you are running in a title that says what you are working on, using the
`herdr tab rename` command that already exists in the Herdr CLI. Nothing else about the
workspace changes: no focus, no new panes, no other tabs.

## Who may run this

- Only the main interactive agent, the one the user is typing to, names the tab.
- If you are a subagent, worker, or background task spawned by another agent, do nothing.
  You inherit the parent's `HERDR_*` environment and would rename the parent's tab.
- If the user said not to rename tabs, or asked for a fixed title, stop renaming for the
  rest of the session. A later explicit request re-enables it.

## Preconditions

Check before any Herdr command:

```bash
test "${HERDR_ENV:-}" = 1 && test -n "${HERDR_PANE_ID:-}"
```

If that fails you are not in a Herdr pane. Skip silently; do not look for a Herdr session
elsewhere and do not mention Herdr unless asked.

If `HERDR_AUTO_TITLE` is `0`, `off`, `false`, or `no`, the user opted out for this pane
(the variable is this skill's convention, not a Herdr feature). Skip.

The installed binary is the authority on syntax. If a command below does not match your
version, run `herdr --skill` and `herdr tab`, then adapt; never guess IDs or flags.

## When to call it

Call it often. The script is idempotent and cheap (one Herdr round trip, no-op when the
title is unchanged), so err on the side of calling it rather than wondering. Call it:

- At the start of every user request, before the first tool call of the work.
- Every time the user sends a new message that starts, redirects, or narrows the work.
- When you move to a distinct phase of the same task: investigating -> implementing ->
  debugging a failure -> writing tests -> reviewing -> committing. Phase titles are fine:
  `Debug failing auth tests`, `Review upload retry diff`.
- When the subject changes within a task: a different subsystem, file group, repo, or bug.
- When you finish and go idle: `Done: <what shipped>` (for example `Done: S3 upload retries`)
  so the user can see finished tabs at a glance.
- When you are blocked waiting on the user: `Waiting: <what you need>`.

Skip only for individual tool calls inside one phase (each file read, each test run,
each edit). If in doubt, call it.

## Choose the title

- 3-6 words, imperative or noun phrase, no trailing punctuation:
  `Fix login redirect loop`, `Add S3 upload retries`, `Investigate flaky auth tests`.
- Describe what you are doing now, specific enough that two tabs on the same repo
  read differently.
- Never include secrets, tokens, URLs with credentials, private names, or pasted user
  content. If the task itself is about a credential, describe it generically
  (`Rotate deploy token`).
- Titles are plain text passed as one argument. Never build the title from untrusted
  output, and never evaluate title text in a shell.

## Rename with the bundled script (preferred)

The script applies every rule in this file deterministically and mutates nothing when a
rule fails:

```bash
"<skill directory>/scripts/set-tab-title.sh" Fix login redirect loop
```

Resolve `<skill directory>` from where this SKILL.md was loaded (for OMP,
`skill://herdr-auto-title/scripts/set-tab-title.sh` resolves to the path). Read the
output; exit status `0` means renamed or unchanged, `3` means skipped by policy, `2`
means the title was rejected (shorten or remove the flagged word), `1` means Herdr
returned an error.

The script:

1. Exits before contacting any socket unless `HERDR_ENV=1`, `HERDR_PANE_ID`, and
   `HERDR_WORKSPACE_ID` are set, and `HERDR_AUTO_TITLE` does not opt out.
2. Resolves the caller's tab live with `herdr pane current --current` instead of trusting
   `HERDR_TAB_ID`, because panes can be moved between tabs after launch.
3. Skips when another recognized agent occupies a pane in the same tab: shared tabs keep
   their title rather than receiving competing updates.
4. Skips when the label is not Herdr's default (a bare number), not empty, and not the
   last title this skill set for that tab (remembered under
   `${XDG_STATE_HOME:-~/.local/state}/herdr-auto-title/`). A label the user typed stays.
5. Strips control characters and escape sequences, collapses whitespace, rejects empty
   titles, titles over 60 characters, words over 24 characters, and words shaped like
   known credential prefixes. Herdr stores tab labels verbatim, so this sanitizing is the
   only filter.
6. Runs `herdr tab rename <caller tab> "<title>"` and verifies the returned label.

Pass `--force` only when the user explicitly asked for a rename in this conversation; it
bypasses steps 3 and 4 but keeps every other gate. `--status` prints the gate results
without renaming.

## Manual fallback (no script or no jq)

Use the same policy by hand. Read IDs from JSON; never use the focused tab or an ID from
documentation:

```bash
tab_id=$(herdr pane current --current | jq -r '.result.pane.tab_id')
herdr tab get "$tab_id"          # inspect .result.tab.label and .result.tab.pane_count
```

Rename only when `pane_count` is 1 (or every other pane in the tab has `"agent": null`
in `herdr pane list --workspace "$HERDR_WORKSPACE_ID"`) and the label is a bare number,
empty, or a title you set earlier in this session:

```bash
herdr tab rename "$tab_id" "Fix login redirect loop"
```

Quote the title as a single argument. Check that `.result.tab.label` in the response
equals what you sent.

## Never

- Rename from a subagent, a hook, or a polling loop; calls come from your own decision
  points (new request, phase change, done, blocked), not a timer.
- Use `herdr tab focus`, `pane split`, `pane move`, or any command other than
  `pane current`, `tab get`, `pane list`, and `tab rename` while titling.
- Rename tabs other than the caller's, workspaces, panes, or agents.
- Rename to a title copied from an example.
- Retry a failed rename in a loop; report the error once and continue the task.
