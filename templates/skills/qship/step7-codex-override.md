# Step 7 Override — Implementation via `codex exec`

This file replaces **only §7.1 (Implementation Loop)** of `~/.claude/skills/qship/pipeline-steps.md`. Everything else inside Step 7 — §7.0 memory search, §7.2 cross-repo order, migration handling, completion check — and every step from 7.3 onward runs unchanged as Claude.

## TL;DR of the swap

| qship §7.1 (provider=claude) | qship §7.1 (provider=codex) |
|---|---|
| Claude reads plan task | Claude reads plan task |
| Claude writes failing test (TDD red) | Claude builds a self-contained prompt, shells to `codex exec` |
| Claude writes minimal impl (TDD green) | Codex writes BOTH the failing test and the impl in one turn |
| Claude runs `pytest`, refactors | Codex runs `pytest` inside its own sandbox; on exit Claude re-verifies |
| Claude commits batch | Claude commits the batch (Codex doesn't push, doesn't open PRs) |

Claude stays the orchestrator. Codex is a per-task subprocess.

## The per-task loop

For each task in `<WORKTREE>/plan.md` (or per-repo plan files):

### 7.1.a Build the prompt

Construct the prompt for Codex from these pieces, IN THIS ORDER:

1. **Project rules excerpt.** Read the relevant CLAUDE.md files for the affected repos and pull the rules that touch the task area. At minimum include:
   - {{COMPANY_SLUG}} monorepo conventions (Decimal not float, soft-delete vs hard-delete, repo-owns-persistence)
   - The "Analogous Code Discovery" rule from `~/.claude/CLAUDE.md`
   - "Extend existing mechanisms, don't create parallel ones"
   - Any feedback memory entries whose `description` matches the task keywords (use `~/.claude/projects/-Users-{{LOCAL_DB_USER}}-work-{{GH_ORG}}-{{COMPANY_SLUG}}-codebase/memory/MEMORY.md` as the index)
2. **The single task** verbatim from the plan, including file paths, acceptance bullets, and analogous-code pointers Claude resolved in §7.0.
3. **TDD directive (mandatory):** Codex MUST first write a failing test that fails for the right reason, then write the minimal implementation, then re-run the test. If TDD doesn't apply (rename/refactor/config), Codex MUST explicitly state that and why — never silently skip TDD.
4. **Bounded scope:** "Do ONLY this task. Do NOT touch unrelated files. Do NOT add features, refactors, or scope from other tasks. Do NOT push, commit, or open a PR — that's the orchestrator's job."
5. **Self-verification:** Codex MUST run `pytest <relevant path>` and report the result inline before exiting. If tests fail, Codex must either fix the impl until green or exit with a clear blocker statement — never edit the test to make it pass, never `pytest.skip`, never `assert True`.
6. **Output contract:** Codex emits a final JSON object on stdout as the last event: `{"task_id": "<N>", "status": "done|blocked", "files_changed": [...], "tests_run": [...], "tests_passed": true|false, "notes": "..."}`. This is what Claude parses to decide go/no-go.

Save the assembled prompt to `<WORKTREE>/codex-runs/task-<N>.prompt.md` for evidence.

### 7.1.b Invoke `codex exec`

```bash
mkdir -p <WORKTREE>/codex-runs

codex exec \
  --model "${QSHIP_CODEX_MODEL:-gpt-5.5}" \
  -c model_reasoning_effort="${QSHIP_CODEX_EFFORT:-high}" \
  --sandbox workspace-write \
  --json \
  --cd <WORKTREE>/<repo-name> \
  - < <WORKTREE>/codex-runs/task-<N>.prompt.md \
  > <WORKTREE>/codex-runs/task-<N>.jsonl \
  2> <WORKTREE>/codex-runs/task-<N>.stderr
CODEX_EXIT=$?
```

Notes on the flags:
- `--sandbox workspace-write` — Codex can edit files in the cwd and run shell commands, but cannot reach outside the worktree. This matches qship's worktree isolation model.
- `--json` — emits one JSON event per line on stdout. Easier to parse than the human stream and survives later automation.
- `--cd <WORKTREE>/<repo-name>` — Codex's working directory is the per-repo subdir of the worktree, same as where Claude would run pytest.
- `-c model_reasoning_effort="${QSHIP_CODEX_EFFORT:-high}"` — read from the env var the orchestrator sets (default `high`). Slower per-task, tighter TDD discipline, fewer silent-failure patterns — the right tradeoff for {{COMPANY_SLUG}} epics with dual-write / RLS / cross-repo invariants. Drop to `medium` only for known-boilerplate epics by exporting `QSHIP_CODEX_EFFORT=medium` before launch.
- We pipe the prompt via stdin (`-` argument) rather than passing it on the command line to avoid shell-escaping pitfalls with multi-paragraph prompts containing quotes.

### 7.1.c Parse the result

Read the last line of `task-<N>.jsonl` — Codex's final JSON object — and the exit code:

- **Exit 0 AND `status: "done"` AND `tests_passed: true`:** proceed to §7.1.d verification.
- **Exit 0 AND `status: "blocked"`:** Codex couldn't complete. Read `notes`, decide whether to (a) re-prompt with more context, (b) raise reasoning effort to high and retry, or (c) take the task over in Claude. Cap at **2 Codex attempts per task**; after that, Claude implements that task directly via the original qship §7.1 TDD loop.
- **Non-zero exit:** read `task-<N>.stderr`. Most common causes: model rate-limit (retry after 30s), sandbox refused a write (means the task wants to touch a file outside `--cd`; either the plan is wrong or Codex misinterpreted — re-prompt or take over).

### 7.1.d Claude verifies (mandatory — do NOT trust Codex's self-report)

Codex's `tests_passed: true` is not authoritative. From the orchestrator side, Claude must:

1. **Capture the diff:** `cd <WORKTREE>/<repo-name> && git diff > <WORKTREE>/codex-runs/task-<N>.diff`
2. **Read the diff.** Confirm files changed match the plan's expected scope. Flag any out-of-scope edits.
3. **Re-run tests from Claude's side:** `cd <WORKTREE>/<repo-name> && pytest <relevant test path> -v`. The same test must pass when Claude runs it; if it doesn't, the workspace is in an inconsistent state — investigate.
4. **Run the FULL repo test suite** every 3 tasks (batch checkpoint per qship §7.1.1) to catch regressions Codex didn't notice.
5. **Run formatters:** `black {{CODEBASE_PATH_PREFIX}}/ && isort {{CODEBASE_PATH_PREFIX}}/ && flake8 {{CODEBASE_PATH_PREFIX}}/` after each task. Codex sometimes ships unformatted code at medium effort. Don't argue with the formatter — let it rewrite, then commit.
6. **Write `task-<N>.summary.md`** — one paragraph: what changed, why, which tests run, anything sketchy. This is the human-readable counterpart to the JSONL.

If verification fails, treat it as a Codex attempt-failure (see §7.1.c) and decide whether to retry or take over.

### 7.1.e Commit the batch

Same as qship §7.1.1 — every 3 completed tasks, commit on the ticket branch with `wip: <TICKET> batch N — <summary>`. Codex never commits (the prompt forbids it); Claude commits from the orchestrator side using the captured diff summaries.

## Migration handling — stays in Claude

Per qship pipeline-steps.md §7 "Migration handling": migrations are autogenerated via alembic, never LLM-generated. **Codex does NOT run alembic.** If a task in the plan requires a migration:

1. Skip that task in the Codex loop.
2. Claude runs the standard qship migration sub-step verbatim (autogenerate, trim drift, run upgrade).
3. Resume Codex tasks afterwards.

The reason is the same as why qship blocks LLM-generated migrations with a PreToolUse hook — autogenerate is the source of truth, predictability of revision IDs matters for chain integrity, and across repos schema ownership is too easy to get wrong from a model that hasn't read those memories.

## What about Steps 7.3, 7.4, 7.45, 7.5?

All run as Claude, unchanged from qship:

| Step | Engine | Why |
|---|---|---|
| 7.3 Directory Organization (`qdirectory`) | Claude | Skill tool not available to Codex. |
| 7.4 Clean Defensive Code (`qclean`) | Claude | Same. |
| 7.45 TRD Mirror Review | Claude | Reads Confluence via MCP. |
| 7.5 Simplify (`code-simplifier` agent) | Claude | Requires Task tool. |

You could theoretically run §7.4 / §7.5 through Codex too, but the wins are marginal and the cost is losing the existing review agents' hard-won taste. Not worth it.

## A/B comparison mode (optional)

If the user sets `QSHIP_AB=true` alongside `provider=codex`, run the implementation twice:

1. **Branch A:** standard `/qship` Step 7 (Claude implements). Save diff to `<WORKTREE>/ab/claude.diff` and a transcript to `<WORKTREE>/ab/claude.transcript.md`.
2. **Branch B:** this override (Codex implements). Save to `<WORKTREE>/ab/codex.diff` and a JSONL bundle.
3. Both must pass the same Phase 2 review independently. Report cost (tokens × $/token), wall-time, and review-iter count side-by-side.

Only pick one to ship; the loser is discarded. A/B mode roughly doubles cost — use it sparingly, e.g. when calibrating which ticket shapes Codex handles well.

## Fallback contract — non-negotiable

If at any point Codex behavior makes the orchestrator unsure (sandbox errors that don't make sense, edits to files not in the plan, tests passing locally to Codex but failing when Claude reruns), **stop the Codex loop and finish the remaining tasks as Claude under standard qship §7.1**. The shipped PR's quality matters more than the cost saving. Write a memory entry (`feedback_qship_codex_<scenario>.md`) capturing what tripped Codex so future tickets can route around it earlier.
