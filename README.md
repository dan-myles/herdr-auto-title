# herdr-auto-title

An [Agent Skill](https://agentskills.io) that teaches an interactive coding agent running
inside [Herdr](https://herdr.dev) to rename its own tab to a 3-6 word summary of the task
it is doing, such as `Fix login redirect loop`. It uses `herdr tab rename` from the existing
Herdr CLI. No plugin, daemon, extra model call, or terminal title escape sequence is involved.

Herdr's own general skill (`npx skills add herdrdev/herdr --skill herdr -g`) stays untouched;
this skill is a separate, narrow, opt-in behavior.

## Behavior

- Runs only when `HERDR_ENV=1` and the caller's pane identity are present. Outside Herdr
  it does nothing and never looks for another session.
- Targets the tab that hosts the calling agent, resolved live through
  `herdr pane current --current`, never the focused tab.
- Renames early and often: at every new user request, on each phase change
  (investigate -> implement -> debug -> test -> review), when done (`Done: ...`), and when
  blocked (`Waiting: ...`). Not per tool call. Repeat calls with the same title are no-ops.
- Preserves labels it did not set: Herdr's default numeric label and titles it wrote
  earlier are replaceable; anything the user typed is left alone unless the user asks.
- Stays quiet in shared tabs: if another recognized agent occupies a pane in the same
  tab, no rename happens.
- Only the main interactive agent renames; subagents are told to stand down because they
  inherit the parent's Herdr environment.
- Sanitizes titles (control characters, escapes, length, credential-shaped words) before
  passing them as a single argument. Herdr stores tab labels verbatim, so this matters.
- Never changes focus, creates panes, or touches other tabs or workspaces.

`skills/herdr-auto-title/scripts/set-tab-title.sh` implements those gates in POSIX sh
(needs `jq`). `SKILL.md` also documents the equivalent manual CLI steps.

## Installation

Installing the skill is passive: the agent sees the skill's name and description and can
load it when relevant. See [Activation](#activation) for automatic behavior.

With the [skills CLI](https://github.com/vercel-labs/skills) (global install; installed
agents are auto-detected; the CLI offers symlink-from-one-canonical-copy or copy):

```bash
npx skills add dan-myles/herdr-auto-title --skill herdr-auto-title -g
```

Verified explicit target:

```bash
npx skills add dan-myles/herdr-auto-title --skill herdr-auto-title -g -a claude-code
# -> ~/.claude/skills/herdr-auto-title
```

Pass `--copy` if symlinks are not wanted.

Manual install (one source copy, symlinked into each harness directory):

```bash
git clone https://github.com/dan-myles/herdr-auto-title ~/.local/share/herdr-auto-title
src=~/.local/share/herdr-auto-title/skills/herdr-auto-title

mkdir -p ~/.agents/skills  && ln -s "$src" ~/.agents/skills/herdr-auto-title   # OMP (v18.1.15+), Codex
mkdir -p ~/.claude/skills  && ln -s "$src" ~/.claude/skills/herdr-auto-title   # Claude Code
```

Where symlinks are unsupported, `cp -R "$src" <dir>/herdr-auto-title` instead. Other
harnesses have their own skill directories (see the skills CLI's supported-agents table);
the skill file is standard, but this repo has only verified the paths above.

## Activation

Two different things:

1. **Installed skill** (above): available on demand. Whether an agent loads it on its own
   at task start depends on the model and harness; it is not a hook or a guarantee.
2. **Persistent instruction** (opt in): a short always-on rule that tells the main agent
   to apply the skill. This is what makes naming automatic in practice.

Add the following to an existing instruction file; do not replace what is already there.

**OMP** — `~/.omp/agent/RULES.md` is sticky (re-attached near every turn). Append:

```markdown
When HERDR_ENV=1 and you are the main interactive agent, keep the tab title current with
the herdr-auto-title skill: call its set-tab-title.sh at the start of every user request,
whenever the task or phase changes, when you finish (Done: ...), and when you are waiting
on the user (Waiting: ...). Subagents never rename the tab.
```

**Claude Code** — append the same lines to `~/.claude/CLAUDE.md` (user instructions,
loaded every session).

**Codex** — append the same lines to `~/.codex/AGENTS.md` (global guidance; Codex reads
`~/.agents/skills` as its user skill location).

Turning it off:

- Remove the snippet to stop automatic use; the skill still works on request.
- Set `HERDR_AUTO_TITLE=off` for a pane (for example `herdr tab create --env HERDR_AUTO_TITLE=off`)
  to make the script refuse to rename there.
- Tell the agent to keep a fixed title; the skill instructs it to stop for the session.
- Uninstall with `npx skills remove herdr-auto-title -g` or by deleting the symlinks.

## Limitations

- Model-driven: a persistent instruction raises the odds that the agent renames at the
  right moments but does not guarantee it, and different harnesses surface skills
  differently.
- Subagent detection is by instruction, not enforcement: Herdr exposes no flag that
  distinguishes a subagent sharing the parent's pane, so the rule relies on the agent
  knowing its own role.
- "User-set label" is inferred: a label that is not Herdr's numeric default and not the
  last title the script wrote is treated as user-owned. The script's memory lives in
  `${XDG_STATE_HOME:-~/.local/state}/herdr-auto-title/` per server socket and tab.
- Requires `jq` for the script; without it the agent falls back to the manual steps in
  `SKILL.md`.
- Tested against Herdr 0.9.0 (`herdr tab rename <tab_id> <label>`); re-check with
  `herdr tab` if a later CLI changes the syntax.

## License

MIT. See [LICENSE](LICENSE).
