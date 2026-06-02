---
name: qship
description: Full Jira-ticket → PR pipeline (plan, implement, review, test, ship). Supports parallel and epic-mode execution. Two independent engine knobs — `provider=claude|codex` chooses the Step 7 implementer (default Claude Opus 4.7 1M, medium reasoning), and `reviewer=claude|codex` chooses the Phase 2 reviewer (default Claude). Most useful combination beyond defaults is `provider=claude reviewer=codex` (Opus implements, gpt-5.5 high reasoning hunts bugs) — different model families catch different defects.
disable-model-invocation: true
argument-hint: "[TICKET-ID...] [provider=claude|codex] [reviewer=claude|codex]"
compatibility:
  required-cli: ["gh", "git", "jq", "pyenv", "alembic", "python>=3.10", "claude"]
  required-mcp: ["atlassian", "claude-context-local", "codegraph"]
  required-paths: ["~/work/{{GH_ORG}}/{{CODEBASE_DIR_NAME}}", "~/.claude/skills/qship/hooks/"]
  required-hooks: ["PreToolUse:require-phase3-evidence.sh", "Stop:require-pipeline-complete.sh", "SubagentStop:require-pipeline-complete.sh"]
  conditional-cli: { "provider=codex": ["codex"] }
  conditional-notes: "provider=codex requires the OpenAI Codex CLI installed and authenticated (`codex --version`, `codex auth status`) with gpt-5.5 in the model picker."
---

> **Issue source — `tracker = {{TRACKER_TYPE}}`** (chosen at onboarding). Follow the issue-source protocol in `$SKILLS_ROOT/qship/references/tracker-contract.md` — it defines, per tracker, how to FETCH / CHILDREN / CREATE / TRANSITION / READ-TRD. For `none`: treat `$ARGUMENTS` as the spec (pasted text or a local file path) and skip all tracker MCP calls.

# qship -- Full Development Pipeline

Orchestrates the complete development lifecycle for one or more Jira tickets. Takes ticket IDs, fetches details from Jira, creates branches, plans implementation, writes code, reviews, hunts for bugs, fixes issues, and creates pull requests.

## ⛔ Read first — autonomy contract & hook enforcement

**Before doing anything, read [references/autonomy-contract.md](references/autonomy-contract.md) in full.** It defines persistence rules, the read-before-execute rule, the no-skip rule, and local-DB pre-authorisation. Every section below assumes you've internalised it. Sub-agents you spawn must read it too — pass them a one-line pointer, never paste the contract verbatim.

A skill is a prompt; prompts can be hallucinated past. qship backs the soft rules with three hard layers: `PreToolUse` blocks PR-create/push without evidence, `Stop`/`SubagentStop` blocks termination while progress files have PENDING rows, and `qship-persist.sh` is the outer ralph loop that keeps re-invoking until `/qshipcheck` says PASSED. Without those hooks the contract is advisory — verify they're wired with `jq '.hooks | keys' ~/.claude/settings.json` (expect PreToolUse, Stop, SubagentStop).

### The three enforcement layers

1. **`PreToolUse` hook — `require-phase3-evidence.sh`** (already wired in `~/.claude/settings.json`)
   Blocks `gh pr create`, `git push ... {{JIRA_PROJECT_KEY}}-*`, and `gh pr comment` when `{{STATE_ROOT}}/worktrees/<EPIC>/phase3-evidence.md` is missing, empty, or lacks HTTP/curl output + a "no network surface" rationale. Keeps Phase 4 from running with fake Phase 3 evidence.

2. **`Stop` + `SubagentStop` hooks — `require-pipeline-complete.sh`** (wired in `~/.claude/settings.json`)
   On every attempted termination, the hook reads `{{STATE_ROOT}}/worktrees/*/phase2-progress.md`, `phase3-evidence.md`, and `trd-coverage.json` (modified within the last `QSHIP_FRESHNESS_MIN=240` minutes) and returns `{"decision":"block","reason":"..."}` whenever:
   - a `phase2-progress.md` row is still `PENDING`, or
   - `phase3-evidence.md` is empty / lacks HTTP evidence / lacks "no network surface" rationale, or
   - `trd-coverage.json` has any row with `passes: false`.
   Includes a `stop_hook_active` guard to prevent infinite loops. Stale worktrees (>4h untouched) are treated as abandoned and do NOT block — delete them to clear stuck blocks. **This is what stops the orchestrator hallucinating completion mid-pipeline** — the LLM no longer decides whether to continue; the progress files do.

3. **Outer persistence loop — `qship-persist.sh`** (ralph pattern wrapper)
   For fully unattended runs, launch qship via:
   ```bash
   bash {{USER_HOME}}/.claude/skills/qship/hooks/qship-persist.sh {{JIRA_PROJECT_KEY}}-42
   # or for a batch:
   MAX_ITERS=15 bash {{USER_HOME}}/.claude/skills/qship/hooks/qship-persist.sh {{JIRA_PROJECT_KEY}}-1 {{JIRA_PROJECT_KEY}}-2 {{JIRA_PROJECT_KEY}}-3
   ```
   This bash loop re-invokes `claude -p "/qship $TICKET"` with a fresh context each iteration until `claude -p "/qshipcheck $TICKET"` prints `PASSED`. State lives in the filesystem (`{{STATE_ROOT}}/worktrees/<TICKET>/`), so each iteration resumes exactly where the previous one left off. Survives context compaction, dropped connections, and rogue "I'm done" completion reports. Logs per-ticket to `{{STATE_ROOT}}/persist-logs/`.

**Permission allowlist (3rd layer of physical unblocking).** The project `.claude/settings.local.json` pre-authorises the bash patterns qship routinely runs (alembic, migration runners, `{{STATE_ROOT}}/worktrees/*` scripts, worktree `cp` commands, `claude -p /qship*`). The text in SKILL.md that says "local DB writes are pre-authorised" now has an actual allowlist backing it — prompts do not auto-approve anything; the JSON file does.

### How the three layers compose

| Failure mode | What catches it |
|---|---|
| Orchestrator says "pipeline complete" with Phase 3 unrun | `PreToolUse` blocks the push/PR |
| Orchestrator tries to yield to user with PENDING rows | `Stop` hook blocks termination, feeds back the specific PENDING steps |
| Context compaction drops the autonomy contract from prompt | `qship-persist.sh` restarts a fresh session and the `Stop` hook immediately picks up the pending state |
| Sub-agent reports "skipped for time" | Orchestrator's progress file still shows PENDING → next iteration continues that step |
| `alembic upgrade head` triggers a permission prompt | Allowlist entry pre-authorises — no pause |

### Hook files

- `~/.claude/skills/qship/hooks/qship-evidence-lib.sh` — shared evidence validator (sourced by the two hooks below)
- `~/.claude/skills/qship/hooks/require-phase3-evidence.sh` — PreToolUse (Phase 4 gate on PR create / epic push)
- `~/.claude/skills/qship/hooks/require-pre-pr-test-pass.sh` — PreToolUse (Step 12.0 gate: blocks `gh pr create` until full test suite is fresh-green per repo via `phase4-tests-passed.<repo>.flag` files)
- `~/.claude/skills/qship/hooks/require-pipeline-complete.sh` — Stop + SubagentStop (anti-yield gate)
- `~/.claude/skills/qship/hooks/qship-compute-context.sh` — classifies the diff into API/UI booleans (run by Phase 1)
- `~/.claude/skills/qship/hooks/qship-persist.sh` — outer loop (ralph wrapper)
- `~/.claude/skills/qship/hooks/qship-watchdog.sh` — one-shot stall detector (file mtime + commit age + suspicious-idle-child sniff). Orchestrator runs this every ~5 min while a Phase 1/2/3/4 worker is in background. See "Worker stall watchdog" below.

### Worker stall watchdog (orchestrator-side loop)

Background workers can wedge mid-step (the canonical failure: an xhigh planner subprocess held open stdio and stalled the worker's Bash tool for 2+ hours on {{JIRA_PROJECT_KEY}}-EX11 — see [feedback_qship_worker_stall_watchdog.md](file://{{USER_HOME}}/.claude/projects/-Users-{{LOCAL_DB_USER}}-work-{{GH_ORG}}-{{COMPANY_SLUG}}-codebase/memory/feedback_qship_worker_stall_watchdog.md)). The harness reports the agent as "running" indefinitely because the agent never finishes a tool call. Without a watchdog the orchestrator silently waits forever.

**Rule for every background worker dispatch:** after `Agent(... run_in_background: true)`, the orchestrator MUST poll progress every 5 minutes via the watchdog. The cheapest mechanism depends on how you were invoked:

| Invocation | Recommended cadence mechanism |
|---|---|
| `/loop 5m /qship <TICKET>` (preferred for unattended) | The /loop interval is itself the watchdog tick — every fire, run `qship-watchdog.sh` and react. |
| In-session `/qship <TICKET>` | After each background dispatch, schedule a re-entry via `ScheduleWakeup delaySeconds=300` (when in /loop dynamic mode) OR manually run `bash ~/.claude/skills/qship/hooks/qship-watchdog.sh <TICKET> --strict` on each turn before sending control back to the user. |
| `qship-persist.sh` outer loop | The persist loop already re-enters every iteration; add a watchdog call near the top of each iteration. |

**Watchdog mechanics** (`qship-watchdog.sh <TICKET>` — exits 0=OK / 1=STALL):
1. **File-mtime check**: newest non-noise file under `{{STATE_ROOT}}/worktrees/<TICKET>/` was modified within `STALL_FILE_MIN` minutes (default 12). A worker actively writing code touches a file at least every few minutes.
2. **Commit-age check**: at least one new commit on the branch within `STALL_COMMIT_MIN` minutes (default 25). Only counts as a stall signal when files are ALSO stale — a worker may be deep in a long edit without committing.
3. **Suspicious-idle-child sniff**: scans for child processes whose argv contains `claude -p` / `codex exec --model` / `--effort xhigh` AND has been alive > `STALL_BG_MIN` minutes (default 30) AND is using < 1% CPU AND does NOT look like the main Claude Desktop process (`--mcp-config` / `--plugin-dir` / `Claude Helper` excluded). This catches the canonical stuck-subprocess pattern.

**When watchdog returns STALL — orchestrator recovery procedure:**

1. **Identify the stuck child** from the watchdog's `suspicious_pids` field. Confirm by `ps -p <pid> -o etime,pcpu,command` — if it's been idle 30+ min with no output, it's hung.
2. **`SendMessage` the worker** by agent ID (NOT by name — the name binding may be stale after session resume) telling it to: (a) `BashOutput`/`KillShell` the hung shell, (b) stop re-planning at xhigh (the Step 5/6 plan is already authoritative), (c) resume from the current branch tip per `phase2-progress.md` PENDING rows, (d) write `phase1-blocker.md` instead of silently hanging if genuinely blocked. The exact recovery prompt is recorded in the memory lesson.
3. **Do NOT redispatch a new worker** unless the SendMessage returns "no agent with that ID" (truly gone) — two workers on the same worktree will rewrite each other's commits.
4. **Re-run the watchdog 5 min later.** If still STALL on a different reason, escalate to the user.

**False-positive defense:** the watchdog is read-only — it never kills processes or touches the worktree. It only reports. The orchestrator is the decision-maker. Tune `STALL_FILE_MIN` / `STALL_COMMIT_MIN` / `STALL_BG_MIN` via env vars for tickets where long-running tests or codex review rounds legitimately take more time than the defaults.

If any of these are missing or not registered in `~/.claude/settings.json`, treat every soft gate below as advisory. Verify with:
```bash
jq '.hooks | keys' ~/.claude/settings.json
# should include: PreToolUse, Stop, SubagentStop
```


> **Evidence format** — the split-evidence (API + UI) contract, Playwright reporter setup, escape rationales, and how to debug a hook block live in [references/evidence-format.md](references/evidence-format.md).


---

## Autonomy contract — see [references/autonomy-contract.md](references/autonomy-contract.md)

The contract is intentionally factored into a separate file so it can be linked (not pasted) into sub-agent prompts. Read it once at the start of an iteration; the rules apply to every step below.

The orchestrator's TL;DR for the rules in that file:
- Don't stop until `/qshipcheck` returns PASSED. Compaction is automatic; persist state to `phase2-progress.md` / `phase3-evidence.md` / `trd-coverage.json`.
- Read referenced skills/files in full before executing. Skimming produces silent failures (e.g., missing `qmanualt` DEV_MODE patches).
- No step may be skipped or substituted. `/qshipcheck` flags violations and re-runs from the first skip.
- Local writes to `{{LOCAL_DEV_DB_NAME}}` are auto-approved; staging/prod still prompt.

## Local development — Python version

qship assumes **pyenv** is on PATH. The codebase requires Python 3.10+ (uses `dict | None` PEP 604 syntax, `match` statements, etc.). The system `python3` on macOS is 3.9.6 and will fail with `TypeError: unsupported operand type(s) for |` on import.

When workers or the orchestrator invoke `pytest`, `alembic`, `python -m black`, or any other Python tool manually, prepend pyenv shims to PATH or use `pyenv exec`:

```bash
export PATH="{{USER_HOME}}/.pyenv/shims:$PATH"
# or:
pyenv exec pytest tests/ -v
# or use the per-repo venv (always 3.11+):
{{CODEBASE_ROOT}}/<repo>/venv/bin/python -m pytest tests/ -v
```

Failure {{JIRA_PROJECT_KEY}}-EX01: orchestrator ran `python -m alembic upgrade head` and hit `SyntaxError: invalid syntax` because `python` resolved to 3.9.6.

## Pipeline Overview

The pipeline runs in 5 phases:

| Phase | Steps | Owner | Purpose |
|-------|-------|-------|---------|
| **Phase 1: Build** | 1–7.4 | Opus sub-agent | Plan, implement, clean up |
| **Phase 1.5: TRD Mirror** | 7.45 | Opus sub-agent (audited by orchestrator) | Line-by-line TRD vs code gap analysis + fix all gaps |
| **Phase 2: Review** | 7.5–11.5 | Opus sub-agents (dispatched by orchestrator) | Simplify, review, bug hunt, fix, verify |
| **Phase 3: Accept** | 14 | Opus sub-agent runs `/qe2etest` (audited by orchestrator) | E2E testing with coverage audit loop |
| **Phase 4: Deliver** | 12–13, 15 | Opus sub-agent (dispatched by orchestrator) | Create PRs, final review, pipeline check |

**All phases use Opus sub-agents** for maximum quality. The orchestrator never executes work itself — it dispatches, monitors, audits, and redispatches.

### All Steps

> **Step numbers are stable identifiers, not a chronological order.** External skills (`qshipcheck`, `qshipphasecheck`, `qshipmaster`, `qshipp2`) reference them by name, so they can't be renumbered without coordinated cross-skill edits. The actual execution order is the **Phase** column: 1 → 1.5 → 2 → 3 → 4. Inside Phase 4, the order is 12 → 13 → 15 (Step 14 is Phase 3). Step 7's *internal* sub-steps (memory search, TDD loop, migration handling, completion check) use unnumbered headings inside `pipeline-steps.md` to avoid colliding with the top-level Steps 7.3/7.4 below.

| # | Phase | Step | What it does |
|---|-------|------|-------------|
| 1 | 1 | Jira Fetch | Retrieve ticket details from Jira via Atlassian MCP |
| 2 | 1 | Repo Detection | Determine which repos are affected (read from repos.json) |
| 3 | 1 | Pull Latest | Fetch and checkout latest `develop` in each affected repo |
| 4 | 1 | Create Branch | Create a feature branch from develop (`<TICKET_ID>-<summary-kebab>`) |
| 4.1 | 1 | Baseline Verify | Run full test suite on clean branch to confirm green baseline |
| 5 | 1 | Write Plan | Generate a detailed implementation plan using the writing-plans skill |
| 6 | 1 | Plan Review | Validate plan against codebase patterns, analogous code, and CLAUDE.md |
| 7 | 1 | Implement (TDD) | Execute the plan with red-green-refactor TDD cycle; batch checkpoints for 5+ task plans |
| 7.3 | 1 | Directory Check | Verify new files are in correct directories; fix misplaced files |
| 7.4 | 1 | Clean Defensive Code | Remove unneeded try/except blocks and redundant null checks |
| **G1** | **Gate** | **Phase 1 Gate** | **Orchestrator audits Phase 1 output for stubs/TODOs before proceeding** |
| 7.45 | 1.5 | TRD Mirror Review + Fix | Opus sub-agent does line-by-line TRD vs code comparison, implements all gaps |
| 7.5 | 2 | Simplify | Run code simplifier agent on all changed code; **§7.5.3 verifies suggestions were APPLIED, not just listed** |
| 8 | 2 | Code Review | **§8.0 complexity tier first** (T1=0 / T2=1 / T3=2 / T4=3 reviewers). Up to four parallel reviewers + qmigrationdevcheck (§8.5.1, alembic) + qauthtrailingslash (§8.6.5, routes) → unified `phase2-findings.md`. T1–T3 mark unused reviewer rows `SKIPPED [tier T<N>]`. |
| 9 | 2 | Bug Hunt | **Fan-out scales with §8.0 tier** — T1=0 / T2=2 / T3=3 / T4=5 bug hunters against the diff |
| 10 | 2 | Bug Validation | Validate qbug findings — filter false positives, confirm real bugs |
| 11 | 2 | Fix Issues | Read `phase2-findings.md`; tick every MUST FIX or move to `Rejected with rationale`. **Universal no-drop rule: NO finding from ANY source may be silently skipped — applies equally to qcheckt, simplifier, Agent 1/2, qauthtrailingslash, qmigrationdevcheck, cross-branch, etc.** |
| 11.5 | 2 | Verification Gate | Fresh test run + formatting check + `phase2-findings.md` closure audit — **hard gate** before Phase 3 |
| 11.6 | 2 | Quick E2E (`/qe2etest`) | Per-worker smoke against the change — fast, cheap, before the full Phase 3 `/qe2etest` run (which uses the complete scenario matrix and delegates UI to `/qmanualt`) |
| 11.7 | 2 | Memory Capture (`/qmemory`) | Persist any reusable lesson from this ticket before Phase 3 |
| **G2** | **Gate** | **Phase 2 Gate** | **Run `/qshipphasecheck phase2` — BLOCKS Phase 3 if ANY step missing** |
| 14 | 3 | E2E Testing | Opus sub-agent runs full E2E, orchestrator audits coverage, redispatches for gaps |
| **G3** | **Gate** | **Phase 3 Gate** | **Run `/qshipphasecheck phase3` — BLOCKS Phase 4 if E2E not done** |
| 12.0 | 4 | Final Test Pass | Full `pytest tests/ -v` per affected repo with fix loop. Drops `phase4-tests-passed.<repo>.flag`. **Enforced by `PreToolUse` hook on `gh pr create`** — no flag → no PR. |
| 12 | 4 | Create PR | Commit, push, and open pull requests targeting `develop` |
| 12.5 | 4 | Watch CI | `gh pr checks --watch` blocks until each PR's CI completes — green → Step 13, red → Step 12.6 |
| 12.6 | 4 | Auto-Fix CI Failures | Fetch `--log-failed`, dispatch fix subagent (with forbidden-fix list), push, loop back to 12.5. `MAX_CI_FIX_ITERS=5`. |
| 13 | 4 | Final Review | Run `code-review:code-review` skill — posts review comments ON the PR |
| 15 | 4 | Pipeline Check | Run `/qshipcheck` to verify all phases completed |

For the detailed instructions for each step, see [pipeline-steps.md](pipeline-steps.md).

For parallel multi-ticket execution, see [parallel-execution.md](parallel-execution.md).

---

## Argument Parsing

Parse `$ARGUMENTS` to extract Jira ticket IDs **and** an optional implementation-engine provider.

### Validation Rules

1. Split `$ARGUMENTS` on whitespace to get a list of tokens.
2. If `$ARGUMENTS` is empty or blank, display usage and **stop**:
   ```
   Usage: /qship <TICKET-ID> [TICKET-ID...] [provider=claude|codex]

   Examples:
     /qship {{JIRA_PROJECT_KEY}}-42                            (single story/task/bug, Claude impl)
     /qship {{JIRA_PROJECT_KEY}}-1 {{JIRA_PROJECT_KEY}}-2 {{JIRA_PROJECT_KEY}}-3                 (multiple stories in parallel, Claude impl)
     /qship {{JIRA_PROJECT_KEY}}-139                           (epic -- auto-expanded into ordered child stories)
     /qship {{JIRA_PROJECT_KEY}}-42 provider=codex             (delegate Step 7 to codex exec gpt-5.5)
     /qship {{JIRA_PROJECT_KEY}}-1 {{JIRA_PROJECT_KEY}}-2 provider=claude       (explicit Claude — same as default)

   Each TICKET-ID must match the pattern: PROJECT-NUMBER (e.g., {{JIRA_PROJECT_KEY}}-1, PROJ-42, DATA-100)
   ```
3. **Extract optional engine-selector tokens first.** Scan the token list for any tokens matching `^provider=(claude|codex)$` or `^reviewer=(claude|codex)$` (case-insensitive on the key, lowercase value):
   - For each match, set `PROVIDER` / `REVIEWER` to the value (lowercased) and remove that token from the list.
   - If either key is specified more than once, error out with: `Error: <key>= specified more than once`.
   - If the value is not `claude` or `codex`, error: `Error: <key> must be 'claude' or 'codex', got '<value>'`.
   - Defaults when absent: `PROVIDER=claude`, `REVIEWER=claude`.
4. For each remaining token, validate it matches the regex `^[A-Z]+-\d+$`:
   - Letters must be uppercase
   - Must contain a hyphen separator
   - Must end with one or more digits
5. If ANY token fails validation, display an error and **stop**:
   ```
   Error: Invalid ticket ID "<token>"
   Expected format: PROJECT-NUMBER (e.g., {{JIRA_PROJECT_KEY}}-1, PROJ-42)
   All provided IDs: <list of all tokens>
   ```
6. Store the validated list as `TICKETS` and the engine as `PROVIDER`.
7. **For each ticket in `TICKETS`**, fetch the issue type (Step 1). If ANY ticket is an **Epic**, switch to [Epic Mode](references/epic-mode.md) for that ticket instead of the standard pipeline.
8. **For non-Epic tickets**, run [Dependency-Aware Branching](references/epic-mode.md) to detect blockers and resolve base branches.

### Provider selection — Claude (default) vs Codex

`PROVIDER=claude` (default): Step 7 is executed by Claude under the standard TDD loop documented in [pipeline-steps.md](pipeline-steps.md) §7.1. The iteration model defaults to **Opus 4.7 1M context (`opus[1m]`) at `medium` reasoning effort** — override via `QSHIP_ITER_MODEL` / `QSHIP_ITER_EFFORT`.

`PROVIDER=codex`: Step 7's TDD inner loop is delegated to `codex exec --model gpt-5.5 -c model_reasoning_effort=high` per task (override effort via `QSHIP_CODEX_EFFORT`). Every other phase (planning, mirror review, simplify, code review, bug hunt, qbcheck, fix, verify, E2E, PR, final review) still runs as Claude. See [step7-codex-override.md](step7-codex-override.md) for the exact override body — including the per-task prompt template, JSONL capture, fallback rule (after 2 failed Codex attempts, Claude takes the task), and the A/B cost comparison.

**When to choose Codex:** boilerplate CRUD, repository methods following an existing pattern, test scaffolding from a precise plan, new endpoints mirroring siblings, straightforward Pydantic schemas. **Do NOT use Codex for:** anything touching `*/alembic/versions/`, RLS / tenant scoping (multi-tenant), cross-repo enum/URL contracts, architectural refactors, or auth code. Those areas have {{COMPANY_SLUG}}-specific gotchas captured in memory that `gpt-5.5` does not load — fall back to `provider=claude`.

**Pre-flight when `PROVIDER=codex`:**

1. Verify codex CLI is installed and authenticated:
   ```bash
   codex --version 2>&1 | head -1
   codex auth status 2>&1 | head -1
   ```
   If either fails, HALT and tell the user: *"provider=codex requires the OpenAI Codex CLI. Install with `npm i -g @openai/codex` and run `codex auth login`."*
2. Verify gpt-5.5 is available: `codex exec --model gpt-5.5 -c model_reasoning_effort=high - <<< "echo ok"` should return without an "unknown model" error.
3. Scan the ticket(s) for carve-out triggers (alembic / migration / RLS / tenant / cross-repo / auth middleware). If matched, surface a warning and ask whether to proceed or rerun with `provider=claude`.

**How `PROVIDER` propagates:**

- Worker subagent (`~/.claude/agents/qship-worker.md` §Step 7) reads `$QSHIP_IMPL_ENGINE`. When `PROVIDER=codex`, export the following before launching workers / persist loop:
  ```
  QSHIP_IMPL_ENGINE=codex
  QSHIP_CODEX_MODEL=gpt-5.5
  QSHIP_CODEX_EFFORT=high      # override via env
  ```
- When `PROVIDER=claude`, leave those env vars unset (the worker defaults to Claude TDD).
- All other hooks, evidence files, progress files, and `/qshipcheck` semantics are unchanged — the override only swaps the inner implementation loop.

### Reviewer selection — Claude (default) vs Codex

`REVIEWER=claude` (default): the review-flavoured steps — Step 6 Plan Review (`qplan`), Step 7.5 Simplify, Step 8 Code Review, Step 9 Bug Hunt, Step 10 qbcheck — run as Claude Task subagents / Skill invocations per [pipeline-steps.md](pipeline-steps.md). Step 11 (Fix) and 11.5+ always remain Claude.

`REVIEWER=codex`: Steps 6, 7.5, 8, 9, and 10 delegate their core *analysis* to `codex exec --model gpt-5.5 -c model_reasoning_effort=high` per agent slot. Claude still orchestrates — it builds the prompts, runs codex, parses the structured output, deduplicates across agent runs, and writes `phase2-findings.md` (and `phase2-progress.md`'s plan-review row for Step 6) in the same format the downstream steps expect. For Step 6 specifically, a `REVISE` verdict triggers Claude to apply the codex punch list to the plan file and re-run Step 6 (max 2 revision rounds); `REJECT` halts the worker. See [reviewer-codex-override.md](reviewer-codex-override.md) for the per-step prompt templates, JSONL capture protocol, and the Step 6 revision loop. Step 11 (Fix), 11.5 (Verification Gate), 11.6 (`/qe2etest`), and 11.7 (`/qmemory`) always stay in Claude — *fixing* review findings, *verifying* the workspace, and *capturing memory* need Claude's skill stack and project-wide context.

**Why this combination is useful:** Different model families surface different defects. Opus 4.7 has dense {{COMPANY_SLUG}}-specific memory (CLAUDE.md, ~/.claude/MEMORY.md, qship skill library) and writes idiomatic code; gpt-5.5 at high reasoning effort is independently strong at adversarial review — running it as the reviewer on Claude-implemented diffs is closer to the "different-model second opinion" pattern already proven by qshipmaster's Sonnet-critic step ([qshipmaster SKILL.md §Final delivery](../qshipmaster/SKILL.md)), but applied earlier in the pipeline where findings still get fixed.

**Skill access for Codex.** `~/.codex/skills/*` symlinks back to `~/.agent-skills/` (which is the same target `~/.claude/skills` points at — single source of truth, see `~/.agent-skills/README.md`). Codex reads SKILL.md frontmatter the same way Claude does; the YAML `name` + `description` fields are interoperable. So when Codex runs as a reviewer, it can invoke `qcheckt`, `qclean`, `qreuse`, `qbug`, `qbcheck`, etc. via its `/skills` mechanism — see the [Agent Skills docs](https://developers.openai.com/codex/skills). Run `sync-agent-skills` after creating or deleting any skill to refresh Codex symlinks.

**Pre-flight when `REVIEWER=codex`:** same codex CLI + gpt-5.5 availability checks as `PROVIDER=codex` above. The two flags are independent — you can run `provider=claude reviewer=codex` without any provider-side preconditions other than the Codex CLI being present.

**How `REVIEWER` propagates:**

- Worker subagent (`~/.claude/agents/qship-worker.md`) reads `$QSHIP_REVIEW_ENGINE`. When `REVIEWER=codex`, export before launching workers / persist loop:
  ```
  QSHIP_REVIEW_ENGINE=codex
  QSHIP_CODEX_REVIEWER_MODEL=gpt-5.5
  QSHIP_CODEX_REVIEWER_EFFORT=high
  ```
- When `REVIEWER=claude`, leave unset — Phase 2 runs the documented Task subagents.

---


> **Dependency-aware branching** — resolving blockers to branches and grouping ad-hoc ticket batches into waves lives in [references/epic-mode.md](references/epic-mode.md).


> **Epic Mode** — epic detection, wave planning, branch stacking, inter-wave migration coordination, cross-branch integration review, and resume live in [references/epic-mode.md](references/epic-mode.md).

## Execution Model

**CRITICAL: The orchestrator (you) IS the user.** There is no human behind the laptop. You are fully autonomous. You NEVER ask the user for decisions — you make them yourself. You NEVER stop because a sub-agent skipped something — you redispatch. You run for as many hours as needed until the task is fully complete.

**The orchestrator NEVER does implementation or testing work itself.** Every phase is executed by a dedicated sub-agent. The orchestrator's job is to:

1. Parse arguments and validate ticket IDs
2. Create worktrees
3. **Dispatch Phase 1 sub-agent** (implementation) — monitor via SendMessage, audit output for stubs/skips
4. **Dispatch Phase 2 sub-agents** (review, bug hunt) — audit findings, dispatch fix agent
5. **Dispatch Phase 3 sub-agent** (E2E testing) — audit coverage, redispatch for gaps
6. **Dispatch Phase 4 sub-agent** (PR creation) — verify PRs created correctly
7. **Run the Dispatch-Audit-Redispatch loop** until every phase passes its quality gate

**⛔ ALL sub-agents MUST be launched in the background** (`run_in_background: true` on the Agent tool). This is critical because:
- The orchestrator must remain free to **proactively monitor** output files for stubs, skips, and shortcuts
- The orchestrator must be able to **SendMessage** to running agents when it detects issues
- Foreground agents block the orchestrator entirely — it cannot check output, send messages, or audit progress
- Background agents notify the orchestrator on completion, so no work is missed

**Never launch a phase sub-agent in the foreground.** The orchestrator's monitoring contract (stub detection, coverage auditing, redispatch) is impossible if blocked waiting for a foreground agent.

### ⛔ Autonomous Orchestrator Contract

**You are the user. There is no one else behind the computer.**

1. **Never ask the user for decisions.** If you need to choose between approaches, pick the one that delivers the most complete result.

2. **Never stop because a sub-agent skipped something.** If a sub-agent skips a scenario, marks something as a stub, or says "this is too complex", you MUST:
   - Send it a message via SendMessage telling it to go back and complete the work
   - If it still skips, dispatch a NEW sub-agent with specific instructions for the skipped work
   - Repeat until the work is done

3. **Proactively monitor Phase 1 (implementation) sub-agents.** While the sub-agent is running:
   - Periodically check its output (read the output file)
   - Look for signs of shortcuts: "stub", "TODO", "placeholder", "deferred", "too complex", "skip"
   - If you see these, immediately SendMessage the sub-agent: "You left X as a stub. This is a core feature from the TRD. Go back and implement it fully."
   - After the sub-agent completes, do a TRD mirror review: compare every TRD requirement against the implementation and flag gaps

4. **Proactively monitor Phase 3 (testing) sub-agents.** While the sub-agent is running:
   - Check its output for "SKIP", "cancelled", "time constraint", "skipped for time"
   - If you see these, immediately SendMessage: "You skipped scenario X. This must be tested. Execute the action, verify the result, take screenshots."
   - After it completes, run the coverage audit (Step 14.6) and redispatch for gaps

5. **The pipeline runs until completion, however many hours it takes.** The goal is:
   - Every TRD requirement implemented (no stubs)
   - Every feature tested E2E (no skips)
   - Every bug found and fixed
   - Every PR created with full test evidence
   - Every review posted

6. **Escalate to user ONLY for:** infrastructure that is genuinely unreachable (e.g., VPN required, credentials expired), or after 3 failed attempts at the same task.

### ⛔ Phase 1 Monitoring: Proactive Stub Detection

While the Phase 1 sub-agent is running, the orchestrator MUST periodically check its output file for signs of incomplete work:

```bash
# Check every few minutes while the sub-agent is running
grep -i "stub\|TODO\|placeholder\|deferred\|skip\|too complex\|too large\|follow-up\|not implemented" <output_file>
```

**If any of these are found:**
1. Immediately send a message to the sub-agent:
   ```
   SendMessage to: <agent-name>
   "You left <X> as a stub/TODO. This is a core feature from the TRD/ticket.
   Go back and implement it fully. Do not defer it. Do not mark it as a
   follow-up. The task is not complete until every requirement is implemented."
   ```
2. After the sub-agent completes, run a **TRD mirror review** (compare every TRD requirement against the code diff) to catch any gaps the sub-agent didn't mention
3. If gaps exist, dispatch a NEW sub-agent to implement the missing pieces

**The orchestrator's mindset:** "If I were the developer who wrote the TRD, would I accept this implementation as complete? Would I sign off on this PR? If not, what's missing?"

### ⛔ Orchestrator Phase 2 + Phase 3 + Phase 4 Execution Contract

After each subagent completes, the orchestrator MUST dispatch Phase 2 (per-ticket review), Phase 3 (E2E testing), and Phase 4 (PR creation + final review) sub-agents. Each step has a precondition gate — you cannot proceed to step N+1 until step N is done.

**Write a progress tracker.** Before starting Phase 2, create a file at `{{STATE_ROOT}}/worktrees/<TICKET_ID>/phase2-progress.md` and update it after each step:

```markdown
# Pipeline Progress — <TICKET_ID>

## Phase 2: Review (per ticket — static analysis)
| Step | Status | Evidence |
|------|--------|----------|
| 7.5 Simplify | PENDING | |
| 8 Review Agent 1 (production) | PENDING | |
| 8 Review Agent 2 (guidelines) | PENDING | |
| 8 Review Agent 4 (spec) | PENDING | |
| 9 Bug Hunt (5 agents) | PENDING | |
| **10 Bug Validation (qbcheck)** | **PENDING** | **⛔ HARD GATE — Phase 2 cannot end without this** |
| 11 Fix Issues | PENDING | |
| 11.5 Verification Gate | PENDING | |

## Phase 3: Accept (once across all tickets — dynamic validation)
| Step | Status | Evidence |
|------|--------|----------|
| 14 E2E Testing | PENDING | |

## Phase 4: Deliver (once across all tickets — PR + final review)
| Step | Status | Evidence |
|------|--------|----------|
| 12 Create PR | PENDING | |
| 13 Final Review | PENDING | |
| 15 Pipeline Check | PENDING | |
```

**Update each row to DONE with evidence** (agent result summary, test counts, PR URLs, etc.) as you complete it. This file is the source of truth for qshipcheck.

**Phase 2 runs per-ticket.** For each ticket, complete all Phase 2 steps (7.5 → 11.5) before moving to the next ticket.

**⛔ GATE G2: After ALL tickets complete Phase 2, run `/qshipphasecheck phase2 <ALL_TICKET_IDS>`.**
- If it returns FAIL → fix missing steps → re-run until PASS
- If it returns PASS → proceed to Phase 3
- **You MUST NOT start Phase 3 without a PASS from qshipphasecheck phase2**

**Phase 3 runs ONCE across all tickets.** After qshipphasecheck phase2 PASSES:
- Step 14 (E2E Testing) tests the *integrated* result across all tickets/repos

**⛔ GATE G3 — HARD HALT before any Phase 4 tool call**

Before the orchestrator runs ANY of: `git push`, `gh pr create`, `gh pr comment`, `/qshipcheck`, or marks the pipeline complete — it MUST perform these checks in order:

1. **Read the evidence file.** Open `{{STATE_ROOT}}/worktrees/<EPIC_ID>/phase3-evidence.md`. If the file does not exist → STOP. Reopen the Phase 3 task, run `/qe2etest` (which traces the diff, drives API/worker/cron triggers live, and delegates UI to `/qmanualt`), and do not proceed.
2. **Verify the evidence is real.** The file must contain ONE of:
   - At least one curl / httpx response body block per changed HTTP endpoint, AND at least one live DB read showing persisted state, OR
   - A "no network surface" rationale naming every changed module and arguing why no endpoint/CLI exists to target.
   An empty `phase3-evidence.md`, a file that only says "tests pass", a file citing `pytest` output as Phase 3 evidence — these are NOT valid. If any of these, treat the gate as FAILED.
3. **Run `/qshipphasecheck phase3 <ALL_TICKET_IDS>`.** If FAIL → run the missing E2E work → loop. If PASS AND step 2 above also passed → proceed to Phase 4.

If the orchestrator reaches Phase 4 without passing this gate, it is considered a PIPELINE FAILURE. The orchestrator MUST:
- Delete any pushed epic branch (`git push --delete origin <branch>`)
- Close any PR opened without Phase 3 evidence
- Reopen the Phase 3 task and run qe2etest
- Re-push and re-open the PR only after evidence exists

Phase 4 output (PRs, review comments, qshipcheck result) captured without Phase 3 evidence is invalid and must be regenerated.

**The skip I (the orchestrator) actually made in one run**: I equated "138 unit tests pass + migration round-trips + schema inspected" with Phase 3 and went straight to `gh pr create`. That is the exact failure mode this gate exists to block. If the future-me is reading this and thinks "backend-only, tests cover it, I can skip" — STOP. Go run a server, hit a curl, write the evidence file. If the change genuinely has no network surface, write the rationale; don't skip silently.

**Phase 4 runs ONCE after Phase 3 gate passes.** After qshipphasecheck phase3 PASSES:
- Step 12 (Create PR) commits, pushes, and creates PRs — code is now final and tested
- Step 13 (Final Review) runs `code-review:code-review` and posts review comments ON the PR
- Step 15 (Pipeline Check) validates every phase ran for every ticket

**Anti-skip rules — concrete failure modes the abstract no-skip rule maps to.** General rationalisations and read-before-execute violations live in [references/autonomy-contract.md](references/autonomy-contract.md); listed here are the qship-specific traps that have actually shipped before.

**The canonical Phase 3 signal is `/qe2etest`** (per-wave in qshipmaster, plus a final epic-end pass) — or `/qmanualt` for full acceptance flows. Evidence files MUST cite that invocation and its PASS/FAIL verdict. Everything below is explicitly NOT a substitute.

Things that are **not** Phase 3, even though they feel close:
- `pytest` passing — that's Phase 2 verification (Step 11.5). Phase 3 hits a running server. **Citing pytest tallies, scenario counts, or assertion counts as Phase 3 evidence is treated as fake-shipped by `qshipphasecheck` and supervisor FINAL VERIFICATION.**
- `TestClient(app).get(...)` blocks inside a pytest file — still in-process integration; not Phase 3.
- A single ad-hoc `curl` captured opportunistically — supplementary at best; the primary signal MUST be `/qe2etest` or `/qmanualt` output.
- `psql` / `information_schema` / `\d` inspection — state verification, never behavior. Acceptable only as a supporting artifact under a `/qe2etest` scenario.
- `alembic upgrade head` succeeding — migration applying is a precondition for Phase 3, not its substance.
- "Backend-only / API-only / covered by unit tests" — those are reasons E2E is cheap, not reasons to skip. If there is genuinely no network surface, write the explicit `no qe2etest surface: <reason>` rationale in `phase3-evidence.md` citing the changed file paths; the supervisor cross-checks against the diff.

Phase ordering traps:
- Starting Phase 2 before Phase 1 subagent completes.
- Starting Phase 3 before every ticket finished Phase 2.
- Starting Phase 4 before Phase 3 evidence exists. PRs capture final tested code only.
- Creating a PR (Step 12) before Step 14 passes.

Counting-and-substitution traps:
- Dispatching fewer agents than specified (3 bug hunters instead of 5 = pipeline FAIL).
- Running a "simplified version" of a skill in place of invoking it via the Skill tool.
- Marking a step DONE without an actual tool call (Skill / Task / Bash) appearing in the transcript.
- Writing `phase3-evidence.md` without a curl/httpx output block per changed endpoint, or without an explicit "no network surface" rationale.
- Proceeding past Step 15 (qshipcheck) without a PASSED result.

### ⛔ qbcheck — Non-Negotiable Phase 2 Gate (Step 10)

**qbcheck is the MANDATORY exit gate for Phase 2. Phase 2 CANNOT be considered complete without qbcheck execution.**

qbcheck (Bug Validation) serves a unique, irreplaceable purpose: it filters the raw findings from the 5 bug hunter agents (Step 9) to separate real bugs from false positives. Without qbcheck:
- False positives get "fixed", introducing unnecessary code changes
- Real bugs get dismissed as noise and ship to production
- Step 11 (Fix Issues) has no validated input to work from

**Enforcement chain (each step feeds the next — skipping breaks the chain):**
```
Step 9 (Bug Hunt) → raw findings (may include false positives)
    ↓
Step 10 (qbcheck) → validated findings (real bugs only)  ⛔ THIS IS THE GATE
    ↓
Step 11 (Fix Issues) → fixes for validated bugs only
    ↓
Step 11.5 (Verification) → confirms fixes don't break anything
```

**How to verify qbcheck was executed:**
1. The progress tracker (`phase2-progress.md`) must show Step 10 as DONE with evidence
2. Evidence must include: number of raw findings received, number validated as real, number rejected as false positive
3. If Step 9 found 0 bugs, qbcheck STILL runs — it confirms the "0 bugs" finding is genuine, not a bug hunter failure

**Chain-of-thought checkpoint — before proceeding past Step 10, reason through:**
```
STOP. Answer these questions before continuing:
1. How many raw bug findings did Step 9 produce? → [number]
2. Did I invoke the qbcheck skill via the Skill tool? → [yes/no]
3. How many were validated as real bugs? → [number]
4. How many were rejected as false positives? → [number]
5. Do the numbers add up (validated + rejected = total)? → [yes/no]

If ANY answer is missing or "no" → GO BACK and execute qbcheck.
```

**Self-review gate — before reporting completion, ask yourself:**

Phase 2 (for EACH ticket):
1. Did I dispatch the code-simplifier agent? (Step 7.5)
2. Did I dispatch exactly 3 review agents? (Step 8)
3. Did I dispatch exactly 5 bug hunter agents? (Step 9)
4. **Did I invoke `/qbcheck` on the raw findings AND record the validation counts?** (Step 10) ⛔
5. Did I fix validated bugs and run tests? (Steps 11 + 11.5)

Gate G2 (after Phase 2, before Phase 3):
6. **Did I invoke `/qshipphasecheck phase2` and get PASS?** ⛔

Phase 3 (once, after gate G2 passes):
7. Did I invoke `/qe2etest`? (Step 14)

Gate G3 (after Phase 3, before Phase 4):
8. **Did I invoke `/qshipphasecheck phase3` and get PASS?** ⛔

Phase 4 (once, after gate G3 passes):
9. Did I create PRs for all affected repos? (Step 12)
10. Did I invoke `code-review:code-review` on each PR? (Step 13)
11. Did I invoke `/qshipcheck` and get PASSED? (Step 15)

If ANY answer is "no", go back and execute the missing step. Do NOT proceed.

Follow the instructions in [parallel-execution.md](parallel-execution.md) for ALL cases — single or multiple tickets. The process is identical:

1. **Fetch Jira ticket** to determine affected repos (Step 1-2 from pipeline-steps.md)
2. **Create git worktrees** — one per affected repo, under `{{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>`
3. Spawn one background subagent per ticket using the Task tool
4. Each subagent receives the full content of pipeline-steps.md and executes the pipeline in its worktree
5. Monitor and collect results from all subagents
6. Proceed to the **Completion Report** section below

### Worktree Creation (per repo)

**IMPORTANT:** The codebase is NOT a monorepo. Each project is a separate git repository:
- `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}` (git repo)
- `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}` (git repo)
- `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}` (git repo)

For each affected repo, create a worktree with a new branch. The base branch is determined by [Dependency-Aware Branching](references/epic-mode.md) — it may be `develop` or an existing blocker branch. Then **immediately copy `.env`**:

```bash
mkdir -p {{STATE_ROOT}}/worktrees/<TICKET_ID>
cd {{CODEBASE_ROOT}}/<repo-name> && git worktree add -b <BRANCH_NAME> {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> <RESOLVED_BASE>

# CRITICAL: Copy .env so alembic, tests, and any config that uses load_dotenv() works in the worktree
cp {{CODEBASE_ROOT}}/<repo-name>/.env {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>/.env

# Initialize codegraph in the new worktree (background, non-blocking) — gives the
# worker semantic search via mcp__codegraph__* tools scoped to the worktree.
codegraph init {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> 2>/dev/null \
  && cp {{CODEBASE_ROOT}}/.codegraph/config.json \
        {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>/.codegraph/config.json 2>/dev/null \
  && nohup codegraph index {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> \
       > /tmp/codegraph-init-<TICKET_ID>-<repo-name>.log 2>&1 &
```

Where:
- `<BRANCH_NAME>` = `<TICKET_ID>-<summary-kebab-case>` (e.g., `{{JIRA_PROJECT_KEY}}-135-gateway-multi-identity-support`)
- `<RESOLVED_BASE>` = the base branch from dependency resolution (defaults to `develop` if no blockers found)

**If worktree creation fails:**
- Check if the worktree already exists:
  ```bash
  git -C {{CODEBASE_ROOT}}/<repo-name> worktree list
  ```
- If it exists from a previous run, tell the user:
  ```
  Worktree already exists at {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>.
  To remove it: git -C {{CODEBASE_ROOT}}/<repo-name> worktree remove {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>
  Then re-run /qship <TICKET_ID>
  ```
- If it fails for another reason (e.g., dirty state, branch conflict), display the git error and **stop**.

---

## Error Handling

### Argument Errors
- No arguments: show usage message and stop
- Invalid format: show the offending token, expected format, and stop
- Do NOT attempt to guess or auto-correct ticket IDs

### Worktree Errors
- Already exists: tell user how to remove and re-run
- Branch conflict: display the git error and stop
- Disk space: display the error and stop

### Pipeline Step Failures
- If any step fails for a ticket, report which step failed and the error
- Mark that ticket as FAILED but let other tickets continue (if multiple)

### Jira / Atlassian Auth Errors
If the Atlassian MCP plugin is not authenticated or returns auth errors:
```
Atlassian auth expired or not configured.
Run /mcp to re-authenticate the Atlassian plugin, then re-run /qship <TICKET_ID>
```
Stop the pipeline -- do not attempt to continue without ticket details.

### Pre-commit Hook Failures
If `git commit` fails due to pre-commit hooks:
1. Read the hook output to identify the issue
2. Fix formatting/linting issues (run `black`, `isort`, `flake8`)
3. Re-stage and create a NEW commit (do NOT amend)

---


> **Completion report format** — results summary tables and worktree cleanup live in [references/completion-report.md](references/completion-report.md).

---

### Phase 3: Acceptance (Orchestrator Only — runs ONCE)

**Phase 3 runs ONCE after ALL tickets have completed Phase 2.**

Phase 3 is fundamentally different from Phase 2:
- **Phase 2** = static analysis (code review, bug hunting in diffs) — runs per ticket
- **Phase 3** = dynamic validation (running servers, hitting endpoints, checking DB state) — runs once across all tickets

**Precondition: ALL tickets must have Phase 2 complete before Phase 3 starts.**

#### ⛔ WHAT COUNTS AS PHASE 3 — non-negotiable definition

Phase 3 E2E requires ALL of the following. Anything less is **not** Phase 3 and the orchestrator MUST reject its own "Phase 3 done" claim if it cannot tick every box below.

1. **A live service process** started from the feature branch (uvicorn / gunicorn / the app's actual entry point) against a real local Postgres. A FastAPI `TestClient` in-process call does NOT count — it bypasses the network, the uvicorn worker lifecycle, and real HTTP middleware ordering.
2. **At least one live HTTP request per changed endpoint** reaches the running service from outside the process (curl / httpx / playwright) and returns a real response.
3. **At least one real DB read** verifies persisted state changed — `psql`, a raw `SELECT` via `create_engine(...)`, or the live API returning the seeded row. Not an ORM mock. Not an assertion on a stub.
4. **Evidence captured** in `{{STATE_ROOT}}/worktrees/<EPIC_ID>/phase3-evidence.md` before Phase 4 is allowed to start. Every changed endpoint gets one curl/response block. Every live DB assertion gets a `psql` or `SELECT` output block.

**Things that ARE NOT Phase 3 (and MUST NOT be substituted):**
- `pytest tests/` passing — that is Phase 2 verification (Step 11.5).
- `alembic upgrade head` succeeding — that is migration verification.
- `information_schema.columns` inspection — that is schema verification.
- `TestClient(app).get(...)` calls inside a pytest file — those are integration tests, still Phase 2.
- "All the tests pass and the migration round-trips" — that is precisely what I (the orchestrator) once tried to claim as Phase 3. It is not Phase 3.

**If the changed work has no network-visible surface** (pure library change, no endpoints, no CLI), the orchestrator MUST write `phase3-evidence.md` with an explicit **"no network surface" rationale** naming every changed module and arguing why it cannot be reached by an HTTP request or CLI invocation. Silence is not acceptance; the rationale must be explicit and visible in evidence.

> Why this section exists: framework-level enforcement beats prompt instructions every time. An LLM will "hallucinate compliance" with a prompt rule if the rule is not backed by something that halts the next tool call. Treat §"HARD HALT" below as the real enforcement; this definition is the floor for self-verification.

### Step 14: E2E Manual Testing

After Phase 2 is complete for every ticket, dispatch a **background** sub-agent for end-to-end acceptance testing:

1. **Dispatch a background sub-agent** (`run_in_background: true`) that invokes `qe2etest`:
   ```
   Agent tool:
     run_in_background: true
     mode: "bypassPermissions"
     prompt: "Invoke the Skill tool for qe2etest with args: <EPIC_ID or TICKET_IDs> — <brief summary>"
   ```

2. **The qe2etest skill will:**
   - Audit the diff and trace every changed code path forward to its production trigger (HTTP endpoint, worker queue, cron, scheduled job)
   - Run `/qspinuplocal` to start the stack (your services + worker) on the feature branches; apply DEV_MODE patches as needed
   - Drive API/worker/cron triggers live against the running stack and verify DB state
   - Delegate any UI surface to `/qmanualt` (Playwright + Claude in Chrome) — qe2etest does NOT drive the UI directly
   - Cover cross-ticket integration when multiple repos/branches are in scope

3. **If E2E tests fail:**
   - Fix the issues in the relevant worktree/branch
   - Re-run the failing tests
   - Re-run Step 11.5 (Verification Gate) if code changed

4. **If E2E tests pass:**
   - Include the test results in the completion report
   - Proceed to Phase 4

---

### Phase 4: Deliver (Orchestrator Only — runs ONCE)

**Phase 4 runs ONCE after Phase 3 (E2E testing) passes.**

Phase 4 creates PRs and runs the final code review. By this point, all code is finalized — reviewed, bug-hunted, fixed, verified, and E2E tested. The PR captures the **final** state of the code.

**Precondition: Phase 3 must be DONE (E2E testing passed).**

### Step 12: Create PR

**For standalone tickets:** Commit, push, and create pull requests for each affected repo. See pipeline-steps.md Step 12 for details.

**For epics:** Create ONE consolidated PR per repo (not one PR per story). See [Epic PR Consolidation](references/epic-mode.md#epic-pr-consolidation).

**Key difference from earlier phases:** The PR description can now include E2E test results as evidence of correctness.


> **Epic PR consolidation** — merging story branches into one consolidated PR per repo lives in [references/epic-mode.md#epic-pr-consolidation](references/epic-mode.md#epic-pr-consolidation).

### Step 13: Final Review

Run `code-review:code-review` on each PR created in Step 12. This posts review comments directly ON the PR where human reviewers will see them.

See pipeline-steps.md Step 13 for details.

### Step 15: Pipeline Completion Check

**MANDATORY — must run before declaring the pipeline complete.**

Invoke `/qshipcheck` to verify all phases were executed:

```
Skill: qshipcheck
Args: <TICKET_IDs or EPIC_ID>
```

qshipcheck will:
1. Verify evidence of every Phase 2 step (7.5, 8, 9, 10, 11, 11.5) for EACH ticket
2. Verify evidence of Phase 3 step (14) across all tickets
3. Verify evidence of Phase 4 steps (12, 13) for each ticket
4. Report which steps were verified vs missing
5. **Automatically run any missing steps** (dispatch agents, invoke skills)
6. Push fixes if remediation was needed

**The pipeline CANNOT be declared complete until qshipcheck reports PASSED.**

### Final Message

```
qship complete. <N> ticket(s) processed: <S> succeeded, <F> failed.

Phase summary:
  Phase 1 (Build):   <N> subagents completed
  Phase 2 (Review):  <N> tickets reviewed, <B> bugs found and fixed
  Phase 3 (Accept):  E2E testing <PASS/FAIL>
  Phase 4 (Deliver): <N> PRs created, final review posted, qshipcheck PASSED
```
