---
name: qmemory
description: Capture a durable lesson from this work into persistent memory — a non-obvious gotcha, a confirmed convention, or feedback worth re-applying on future tasks. Use when you learn something that should outlive the session; qship runs it as Step 11.7 to record review/bug lessons.
---

# Knowledge Item Memory Storage

Review the current conversation and extract **generic, reusable lessons** worth carrying into future sessions. Save them through Claude Code's auto-memory system so they show up automatically next time.

This skill is the manual end-of-conversation companion to the auto-memory system already described in your system prompt. **Defer to that system as the source of truth** — this skill just walks you through running it deliberately at session end. If anything here conflicts with the auto-memory rules in the system prompt, the system prompt wins.

## Where memories live

Use the auto-memory directory for **the current project** — do not hardcode a path. It's the directory referenced as the memory location in the system prompt's auto-memory section (typically `~/.claude/projects/<project-slug>/memory/`). The index file is `MEMORY.md` in that same directory.

If you cannot determine the project's memory directory from the system prompt, ask the user before writing anything.

## What to extract (and what to skip)

**Worth saving** — anything that will help a future session that doesn't have this conversation's context:
- **Corrections** — the user told you to stop doing X, or to do Y instead. Save the rule + the *why*.
- **Validated non-obvious successes** — you took an unusual approach, the user confirmed it ("yes, exactly", "perfect, keep doing that"), and a future Claude wouldn't guess this from the code alone. These are easy to miss because they're quiet — watch for them.
- **Project facts with a deadline or owner** — merge freezes, who's driving an initiative, the *reason* behind a rewrite. Convert relative dates to absolute (`Thursday` → `2026-05-07`).
- **External system pointers** — "bugs live in Linear project X", "oncall watches dashboard Y".
- **User profile signals** — role, expertise, what framings they prefer.

**Do NOT save** (these are derivable or ephemeral, even if the user asks):
- Code patterns, file paths, conventions, architecture — `grep`/`Read` the codebase next time.
- Git history, recent commits, who-changed-what — `git log`/`git blame` is authoritative.
- Debug solutions or fix recipes — the fix is in the commit, the reasoning in the message.
- Anything already in `CLAUDE.md`.
- In-progress task state, current conversation context, today's TODO list.

If the user asks you to save something on this list, push back: ask what was *surprising* or *non-obvious* about it — that's the part worth keeping, if anything.

## Memory types and body structure

Pick the type that fits, and match the body structure to the type. The structures differ on purpose — `feedback` and `project` decay or get edge-cased, so they need a *why* you can audit later; `user` and `reference` are simpler facts.

| Type | Use for | Body structure |
|---|---|---|
| `feedback` | Rules about how to work — corrections and validated successes | Rule (one sentence). Then **Why:** (the incident or reasoning). Then **How to apply:** (when this kicks in). |
| `project` | Time-bound facts: initiatives, deadlines, motivations | Fact (one sentence). Then **Why:** (the driving constraint). Then **How to apply:** (how it shapes future suggestions). |
| `user` | Stable info about the user — role, expertise, preferences | Free-form prose. No Why/How needed. |
| `reference` | Pointers to external systems | Free-form prose: where it lives, what it's for, when to consult it. |

## File format

```markdown
---
name: Short descriptive title
description: One-line hook used to decide relevance later — be specific
type: feedback | project | user | reference
---

<body — structure depends on type, see table above>
```

Filename: prefix by type — `feedback_<topic>.md`, `project_<topic>.md`, `user_<topic>.md`, `reference_<topic>.md`. Topic should be terse and semantic, not chronological.

## Updating MEMORY.md

`MEMORY.md` is the index, not a memory. Each entry is one line, **under ~150 chars**, in this exact format:

```
- [Title](filename.md) — one-line hook
```

No frontmatter. Lines past 200 get truncated by the loader, so keep it tight. Group entries under the existing semantic headers (`## Key Learnings`, `## Codebase Patterns`, etc.) — don't add chronological sections.

## Before writing — check for duplicates and staleness

1. **Read `MEMORY.md`** to see what already exists.
2. If a similar memory exists:
   - **Update it** rather than creating a new one. Tighten the rule, refresh the *why* with the new incident, extend *How to apply* if the scope has grown.
   - If the new lesson **contradicts** an existing memory, the new one wins — edit the old file (or delete it) rather than letting both sit.
3. If a memory is clearly outdated by what you saw this session (file moved, flag removed, person changed roles), fix or remove it while you're in there.

## Worked examples

### Feedback — correction
```markdown
---
name: Don't mock the database in integration tests
description: Integration tests must hit a real DB; mocking masked a broken migration last quarter
type: feedback
---

Integration tests in this repo must run against a real database, not a mock.

**Why:** Q4 incident — mocked tests passed but the prod migration failed because the mock didn't enforce the same constraints. Mocks made the bug invisible until rollout.

**How to apply:** When adding tests under `tests/integration/**`, wire them to the real test DB fixture. Save mocking for unit-test scope only.
```

### Feedback — validated success (don't skip these)
```markdown
---
name: Bundle related refactors into one PR in this area
description: User confirmed a single bundled PR was preferable to splitting — splits would have been churn
type: feedback
---

For refactors touching the matchers module, prefer one bundled PR over several small ones.

**Why:** I split a similar refactor into 4 PRs and the user pushed back — said the splits created review churn without isolating risk, since the changes only made sense together. The bundled approach was confirmed correct on the next attempt.

**How to apply:** When refactoring across `matchers/*.py`, default to one PR. Split only if a piece can land and be reviewed independently with real value.
```

### Project — time-bound fact
```markdown
---
name: Mobile release freeze 2026-05-07
description: Non-critical merges paused after 2026-05-07 for mobile release branch cut
type: project
---

Merge freeze for non-critical changes begins 2026-05-07 ahead of the mobile release branch cut.

**Why:** Mobile team is cutting the release branch and wants a stable base — every late merge forces a re-cut.

**How to apply:** For any non-critical PR planned after 2026-05-07, flag the freeze to the user and offer to defer or scope down. Critical fixes still go through.
```

### Reference
```markdown
---
name: Pipeline bugs tracked in Linear PIPELINE
description: Linear project PIPELINE is where pipeline-related bugs live
type: reference
---

Pipeline bugs and ingestion incidents are tracked in the Linear project `PIPELINE`. Check there for context on tickets, prior fixes, and ongoing investigations before opening a new bug.
```

## Deliverable for this run

1. Identify the project's memory directory from the auto-memory system context (don't hardcode).
2. Read `MEMORY.md` to load what already exists.
3. Extract **2–5 lessons** from this session, drawing from corrections AND validated successes. Skip anything on the "do not save" list.
4. For each lesson: check for an existing memory to update first; otherwise write a new file with type-appropriate frontmatter + body.
5. Update `MEMORY.md` — one line per new entry, under the right semantic header, under 150 chars.
6. Report back: list each title, whether it was new or an update, and one sentence on why it's worth keeping.
