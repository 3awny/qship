# Pipeline Steps

Detailed instructions for each step of the qship development pipeline. This file is referenced by SKILL.md. All placeholders (`<WORKTREE_PATH>`, `<TICKET_ID>`, `<BRANCH_NAME>`, `<AFFECTED_REPOS>`) are established by the orchestrator before these steps execute.

## Table of contents

| Phase | Steps |
|-------|-------|
| **0 — Read first** | Autonomy contract pointer · Completion-report template · Memory read/write rhythm |
| **1 — Build (subagent)** | 1 Jira Fetch · 2 Repo Detection · 3 Pull Latest · 4 Create Branch · 4.1 Baseline Verify · 5 Write Plan · 6 Plan Review · 7 Implement (TDD) · 7.3 Directory Check · 7.4 Clean Defensive Code |
| **1.5 — TRD Mirror** | 7.45 TRD Mirror Review + Implement Gaps |
| **2 — Review (orchestrator)** | 7.5 Simplify (with §7.5.3 apply-suggestions enforcement) · 8 Code Review (incl. §8.5.1 qmigrationdevcheck, §8.6.5 qauthtrailingslash, §8.8 unified findings file) · 9 Bug Hunt · 10 Bug Validation (qbcheck) · 11 Fix Issues · 11.5 Verification Gate · 11.6 Quick E2E (`/qe2etest`) · 11.7 Memory Capture (`/qmemory`) |
| **3 — Accept** | 14 E2E Manual Testing (`/qe2etest`) |
| **4 — Deliver** | 12.0 Final Test Pass (hard gate, hook-enforced) · 12 Create PR · 12.5 Watch CI · 12.6 Auto-Fix CI Failures · 13 Final Review (`code-review:code-review`) · 15 Pipeline Completion Check (`/qshipcheck`) |

Step ordering is non-monotonic by design (e.g., 11.x sub-steps run before 12 / 13 / 14 / 15 because Phase 3 sits between Phase 2 and Phase 4). Use the table to navigate; don't infer order from numeric prefixes.

---

## Read first

The autonomy + read-before-execute + no-skip rules live in [SKILL.md](SKILL.md#-read-first--autonomy-contract--hook-enforcement) → [references/autonomy-contract.md](references/autonomy-contract.md). Don't restate them here. The completion-report format below is what the orchestrator audits.

The pattern that historically failed: subagents skipped Steps 7.4, 7.5, 8, 9, 10, 13 by performing "simplified self-reviews" instead of invoking the required skills/agents. Skills contain domain-specific logic a self-review cannot replicate — when the spec says "invoke `qcheckt`", invoke `qcheckt`.

### Completion Report Format (MANDATORY)

The canonical step list lives in [SKILL.md → All Steps](SKILL.md#all-steps). The completion report below covers only what the per-ticket subagent runs (Phase 1 + 1.5); everything from Step 7.5 onward is deferred to the orchestrator. **If SKILL.md adds or renames a step, regenerate this template — do not hand-edit row-by-row.**

```
PIPELINE EXECUTION REPORT — <TICKET_ID>
========================================
Step 1   Jira Fetch:           [DONE]      Summary: <ticket summary>
Step 2   Repo Detection:       [DONE]      Repos: <list>
Step 3   Pull Latest:          [DONE/SKIPPED — worktree provided by orchestrator]
Step 4   Create Branch:        [DONE/SKIPPED — branch provided by orchestrator]
Step 4.1 Baseline Verify:      [DONE]      Tests passing on clean branch: <count>
Step 5   Write Plan:           [DONE]      Plan: <plan file path>
Step 6   Plan Review:          [DONE]      Result: <passed/revised>
Step 7   Implement (TDD):      [DONE]      Files changed: <count> | TDD cycles: <count>
Step 7.3 Directory Check:      [DONE]      Skill invoked: qdirectory | Issues: <count>
Step 7.4 Clean Defensive:      [DONE]      Skill invoked: qclean | Removals: <count>
Step 7.45 TRD Mirror + Fix:    [DONE]      Gaps found: <count> | Gaps fixed: <count>
--- Phase 2 (Review) — DEFERRED TO ORCHESTRATOR ---
Step 7.5  Simplify:            [DEFERRED]  (orchestrator-only — requires Task tool)
Step 8    Code Review:         [PARTIAL]   qcheckt invoked by subagent | Agents 1+2+4 + qmigrationdevcheck + qauthtrailingslash: [DEFERRED]
Step 9    Bug Hunt:            [DEFERRED]
Step 10   Bug Validation:      [DEFERRED]
Step 11   Fix Issues:          [DEFERRED]
Step 11.5 Verification Gate:   [DEFERRED]  (subagent reports tests + format outcome only)
Step 11.6 Quick E2E:           [DEFERRED]
Step 11.7 Memory Capture:      [DEFERRED]
--- Phase 3 (Accept) — DEFERRED TO ORCHESTRATOR ---
Step 14   E2E (qe2etest):      [DEFERRED]  Runs once after all tickets complete Phase 2
--- Phase 4 (Deliver) — DEFERRED TO ORCHESTRATOR ---
Step 12.0  Final Test Pass:     [DEFERRED]  pytest per repo + flag — hook-enforced before gh pr create
Step 12    Create PR:           [DEFERRED]
Step 12.5  Watch CI:            [DEFERRED]  gh pr checks --watch
Step 12.6  Auto-Fix CI:         [DEFERRED]  loop until green or MAX_CI_FIX_ITERS=5
Step 13    Final Review:        [DEFERRED]  code-review:code-review
Step 15    Pipeline Check:      [DEFERRED]  /qshipcheck
```

**If a step genuinely cannot execute** (e.g., no tests exist, skill tool unavailable), you MUST:
1. Report it as `[BLOCKED]` with the specific error message
2. Explain why it was blocked
3. Do NOT silently skip it or replace it with a "simplified" version

### ⚡ MEMORY: Read AND Write Throughout the Pipeline

**READ memories** at these stages — search for relevant lessons before acting:
- **Step 5 (Plan):** Search for architecture, patterns, cross-repo, analogous code lessons
- **Step 6 (Plan Review):** Search for lessons related to the specific feature area
- **Step 7 (Implement):** Search for coding patterns, API contracts, enum casing, response formats
- **Step 9 (Bug Hunt):** Search for common bug patterns (204 handling, global scope, deadlocks)
- **Step 11 (Fix Issues):** Search for fix patterns to avoid introducing new bugs
- **Step 14 (E2E Testing):** Search for DEV_MODE workarounds, local setup gotchas

**WRITE memories** whenever you encounter something reusable — run `/qmemory` (or write directly to memory files) at any point during the pipeline when you:
- Fix a bug that could recur (especially cross-component issues like the 204 fix needed in 3 places)
- Discover a codebase pattern not already documented (API response wrapping, enum casing rules)
- Hit a DEV_MODE/testing gotcha (deadlocks, dotenv override, missing patches)
- Find that a UI interaction fails silently (modal doesn't close, data doesn't load, counts don't update)
- Learn something about cross-repo API contracts (URL formats, request/response schemas)
- Encounter a Dash/React integration issue (global store scope, callback dependencies)

**Don't wait until the end** — write the memory AS SOON AS you learn the lesson. If you fix a bug in Step 7, write the memory in Step 7. Don't defer to Step 15.

---

## Step 1: Jira Fetch

**Goal:** Retrieve the full Jira ticket details so we know what to build.

1. Use the `ToolSearch` tool to load the Atlassian MCP tools:
   ```
   ToolSearch query: "+atlassian getJiraIssue"
   ```
2. Fetch ticket details:
   ```
   mcp__plugin_atlassian_atlassian__getJiraIssue(
     issueIdOrKey="<TICKET_ID>"
   )
   ```
   - If the Atlassian plugin is not authenticated, stop and tell the user: "Atlassian auth expired. Run `/mcp` to re-authenticate, then re-run `/qship`."
3. Extract and store these fields for later steps:
   - **Summary** (used for branch name and PR title)
   - **Description** (full problem statement)
   - **Acceptance Criteria** (from description or subtasks)
   - **Issue Type** (Task, Bug, Story, etc. -- determines commit prefix)
   - **Project Key** (e.g., `{{JIRA_PROJECT_KEY}}`)
4. Display a brief summary to the user:
   ```
   Ticket: <TICKET_ID>
   Summary: <summary>
   Type: <issue type>
   ```

---

## Step 2: Repo Detection

**Goal:** Determine which repos in the monorepo are affected by this ticket.

1. Analyze the ticket summary, description, and acceptance criteria.
2. Map ticket content to repos using these heuristics:

   | Keywords / Concepts | Repo |
   |---------------------|------|
   | API, data models, organizations, accounts, records, files, multi-tenant, auth, migrations | `{{PRIMARY_REPO_NAME}}` |
   | ERP, sync, external CRM/accounting connector, connectors, RPA, webhooks | `{{PRIMARY_REPO_NAME}}` |
   | domain-specific processing / business logic | the domain repo that owns that concern (see `repos.json`) |
   | Frontend, React, Dash, UI pages, components, layout, app.py, callbacks | `{{PRIMARY_REPO_NAME}}` |

   **Note:** `[Frontend]` prefixed tickets map to `{{PRIMARY_REPO_NAME}}` — frontend code (React components, Dash pages) lives inside that repo, not in a separate frontend repository.

3. Check acceptance criteria against ALL repos -- changes in one repo may require updates in dependent repos (your repos depend on {{PRIMARY_REPO_NAME}}).
4. If ambiguous, include ALL repos (your repos).
5. Store the list of affected repos as `<AFFECTED_REPOS>`.
6. Report to user:
   ```
   Affected repos: <fill from repos.json>
   ```

---

## Step 3: Pull Latest (qnew)

**Goal:** Ensure each affected repo has a clean, up-to-date `develop` branch.

For EACH repo in `<AFFECTED_REPOS>`:

1. Navigate to the repo directory:
   ```bash
   cd <WORKTREE_PATH>/<repo-name>
   ```
2. Fetch and pull latest develop:
   ```bash
   git fetch origin && git checkout develop && git pull origin develop
   ```
3. Read the CLAUDE.md files for context:
   - Monorepo root: `<WORKTREE_PATH>/CLAUDE.md`
   - Repo-specific: `<WORKTREE_PATH>/<repo-name>/CLAUDE.md` (if it exists)
4. Verify clean state:
   ```bash
   git status
   ```
   - If there are uncommitted changes, stash them (`git stash`) and continue. Note the stash in the completion report so the user can recover it later.

**Valid repo names:** your repos

---

## Step 4: Create Branch (qcheckout)

**Goal:** Create a feature branch from develop in each affected repo.

### Branch Name Generation

1. Take the ticket key: `<TICKET_ID>` (e.g., `{{JIRA_PROJECT_KEY}}-42`)
2. Take the ticket summary from Step 1 (e.g., "Fix login timeout issue")
3. Generate kebab-case branch name:
   - Lowercase the summary
   - Replace spaces with hyphens
   - Remove special characters (keep only alphanumeric and hyphens)
   - Truncate to reasonable length (under 60 chars total)
   - Format: `<TICKET_ID>-<summary-kebab-case>` (e.g., `{{JIRA_PROJECT_KEY}}-42-fix-login-timeout-issue`)
4. Store as `<BRANCH_NAME>`

### Create Branch

The base branch and PR target are provided by the orchestrator as `<BASE_BRANCH>` and `<PR_TARGET>`.

- **Standalone ticket** (not from epic): `BASE_BRANCH = develop`, `PR_TARGET = develop`
- **Epic Wave 1 story**: `BASE_BRANCH = develop`, `PR_TARGET = develop`
- **Epic Wave N story (same-repo chain)**: `BASE_BRANCH = <blocker-story-branch>`, `PR_TARGET = <blocker-story-branch>`
- **Epic Wave N story (cross-repo dep only)**: `BASE_BRANCH = develop`, `PR_TARGET = develop`

For EACH repo in `<AFFECTED_REPOS>`:

```bash
cd <WORKTREE_PATH>/<repo-name> && git checkout -b <BRANCH_NAME> <BASE_BRANCH>
```

Verify:
```bash
git status
```

### 4.0.1 Install pre-commit hook (idempotent)

Each {{COMPANY_SLUG}} repo ships a `.pre-commit-config.yaml` (detect-secrets, autoflake, isort, black, flake8, trailing-whitespace). Worktrees do NOT inherit installed git hooks — `pre-commit install` only writes `.git/hooks/pre-commit`, which is per-worktree. Without this, every `git commit` in the worktree silently bypasses the very gates Step 12.5/12.6 has to clean up after.

```bash
cd <WORKTREE_PATH>/<repo-name>
if [ -f .pre-commit-config.yaml ]; then
  pre-commit install --install-hooks 2>/dev/null || true
  echo "pre-commit installed in $(pwd)"
fi
```

`--install-hooks` pre-fetches the hook envs so the first commit isn't slow. Failure here is non-fatal (the worktree still functions; commits just won't trigger pre-commit locally — Step 12.5/12.6 will catch issues in CI). If `pre-commit` itself is missing, `pip install pre-commit` once at the user level.

### 4.1 Clean Baseline Verification (CRITICAL)

**Before implementing anything, confirm the base branch is green.** Run the full test suite on the clean branch:

For EACH repo in `<AFFECTED_REPOS>`:
```bash
cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v 2>&1 | tail -20
```

**If all tests pass:** Proceed to Step 5. Record the baseline test count (e.g., "47 passed") — you'll compare against this later.

**If tests fail on the clean branch:**
1. Record which tests fail and the error messages
2. Report to the user:
   ```
   WARNING: <N> tests fail on clean <BASE_BRANCH> in <repo-name> before any changes.
   Failing tests:
     - tests/path/test_foo.py::test_bar — <error>
     - tests/path/test_baz.py::test_qux — <error>

   Options:
   1. Proceed anyway (these failures are pre-existing and unrelated)
   2. Abort and fix develop first
   ```
3. Wait for the user's decision before proceeding
4. If proceeding: note the pre-existing failures so they are NOT blamed on your implementation later

Report to user:

| Repo | Branch | Based on | PR targets | Baseline Tests |
|------|--------|----------|------------|----------------|
| {{PRIMARY_REPO_NAME}} | `<BRANCH_NAME>` | `<BASE_BRANCH>` | `<PR_TARGET>` | 47 passed |
| {{PRIMARY_REPO_NAME}} | `<BRANCH_NAME>` | `<BASE_BRANCH>` | `<PR_TARGET>` | 32 passed |

---

## Step 5: Write Implementation Plan

**Goal:** Create a detailed, step-by-step implementation plan for the ticket.

**Why this step gets its own `claude --print` subprocess.** The plan is the highest-leverage decision in the per-ticket pipeline — a wrong plan cascades through Steps 6 → 11.5. So Step 5 runs as a **dedicated subprocess at `xhigh` reasoning effort**, separate from the worker iter loop (which runs at `medium` per `qship-persist.sh`). The planner subprocess gets the full ticket context but spends its xhigh budget exclusively on plan quality.

### 5.1 Gather context (worker iter context, medium effort)

Before dispatching the planner subprocess, the worker collects:
- Ticket summary + description + acceptance criteria (from Step 1)
- Affected repos (from Step 2)
- Analogous-code file paths discovered via `mcp__claude-context-local__search_codebase` for each component the ticket touches
- Relevant CLAUDE.md rules (monorepo + per-repo)
- Relevant memory entries (semantic search via `mcp__basic-memory__search_notes` for tags `planning`, `architecture`, `code-patterns`, `analogous-code`, `pre-coding`, `monorepo`, `cross-repo`)

Write the gathered context to `<WORKTREE>/plan-context.md`. Keep it tight — the planner subprocess reads this file in full and shouldn't have to re-derive it.

### 5.2 Dispatch the planner subprocess

Use the Bash tool:

```bash
PLAN_FILE="<WORKTREE>/docs/plans/$(date +%Y-%m-%d)-<feature-slug>.md"
mkdir -p "$(dirname "$PLAN_FILE")"

claude --print --dangerously-skip-permissions \
    --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,TodoWrite,WebSearch,WebFetch' \
    --model "${QSHIP_PLAN_MODEL:-opus[1m]}" \
    --effort "${QSHIP_PLAN_EFFORT:-xhigh}" \
    --append-system-prompt 'PLANNING MODE. Produce a complete, accurate, executable implementation plan. Organise by repo and by phase. Include every change required, with explicit file paths, function/class targets, signature changes, and acceptance-test outline. Cross-reference analogous code. Do NOT implement anything — only write the plan file.' \
    "Use the superpowers:writing-plans skill. Read <WORKTREE>/plan-context.md for the ticket + analogous-code context. Write the implementation plan to $PLAN_FILE. When superpowers:writing-plans asks about execution approach, choose neither — qship handles execution in Step 7." \
    > "<WORKTREE>/logs/step5-plan.log" 2>&1
```

### 5.3 Verify the plan was written

If `$PLAN_FILE` is missing or empty after the subprocess returns:
1. Record `Step 5 Write Plan: FAILED iter 1 (subprocess wrote no plan file)` in `phase2-progress.md`.
2. Retry once at fallback effort: re-dispatch with `QSHIP_PLAN_EFFORT=high`.
3. If still empty after the retry, ESCALATE — the planner subprocess is stuck; investigation needed before continuing.

### 5.4 Read the plan back into worker context

The worker reads `$PLAN_FILE` into its context for Step 6 (review) and Step 7 (implementation).

**Override knobs:** `QSHIP_PLAN_MODEL` (default `opus[1m]`), `QSHIP_PLAN_EFFORT` (default `xhigh`). These are the same env vars used by `qshipmaster-plan.sh` — both planning operations share defaults intentionally.

---

## Step 6: Plan Review (qplan)

**Goal:** Review the plan against codebase patterns, analogous code, and CLAUDE.md guidelines before implementing.

**Why this step gets its own `claude --print` subprocess.** Reviewing a plan needs deeper reasoning than the worker iter default — a missed reviewer finding ships a broken plan to Step 7. Step 6 runs as a **dedicated subprocess at `high` reasoning effort**, slightly below the planner (xhigh) but well above the worker iter default (medium).

### 6.0 Reviewer engine selection

**If `$QSHIP_REVIEW_ENGINE` equals `codex`** (set when the user invoked `/qship` or `/qshipmaster` with `reviewer=codex`), STOP following the default qplan path below. Instead follow the **Step 6 — Plan Review** section of `~/.claude/skills/qship/reviewer-codex-override.md`. The codex path delegates to `codex exec --model gpt-5.5 -c model_reasoning_effort=high` with its own subprocess shape.

If `$QSHIP_REVIEW_ENGINE` is unset or equals `claude`, run §6.1 below.

### 6.1 Dispatch the reviewer subprocess

Context note: Step 5.1 already gathered analogous code + memory hits into `<WORKTREE>/plan-context.md`, so the reviewer subprocess reads that file rather than re-deriving — saves time and tokens.

Use the Bash tool:

```bash
REVIEW_FILE="<WORKTREE>/plan-review.md"

claude --print --dangerously-skip-permissions \
    --allowedTools 'mcp__*,Bash,Read,Grep,Glob,TodoWrite,WebSearch,WebFetch' \
    --model "${QSHIP_PLAN_REVIEW_MODEL:-opus[1m]}" \
    --effort "${QSHIP_PLAN_REVIEW_EFFORT:-high}" \
    --append-system-prompt 'PLAN REVIEW MODE. Critique the implementation plan against the codebase, CLAUDE.md, and the acceptance criteria. Output a verdict (PASS / REVISE / REJECT) and a punch list of specific changes the plan author should make. Do NOT rewrite the plan — only identify what needs to change.' \
    "Use the qplan skill to review $PLAN_FILE. Source-of-truth for requirements is <WORKTREE>/plan-context.md (already written by Step 5.1, contains ticket summary + AC + affected repos + analogous code + memory hits). Write your verdict + punch list to $REVIEW_FILE in the qplan-defined format (Verdict + Punch list + Analogous code coverage + AC coverage + Risk notes)." \
    > "<WORKTREE>/logs/step6-review.log" 2>&1
```

### 6.2 Read the verdict + act

The verdict line in `$REVIEW_FILE` (per qplan SKILL.md format) is one of:

- **`PASS`** → record `Step 6 Plan Review: [DONE] Result: passed` in `phase2-progress.md`, proceed to Step 7.
- **`REVISE`** → apply each punch-list item to `$PLAN_FILE` (in the worker's iter context at medium effort — these are surgical text edits driven by the explicit punch-list bullets, not new reasoning). Then re-dispatch §6.1. **Maximum 2 revision rounds**; after that, ESCALATE.
- **`REJECT`** → halt the worker, surface the verdict to the user/orchestrator, do NOT proceed to Step 7.

### 6.3 Plan Validation Checklist (rubric reference)

The reviewer subprocess applies this rubric (already encoded in qplan SKILL.md, repeated here as orchestrator-visible documentation):

- **Consistent with codebase** — follows existing patterns found in analogous code
- **Minimal changes** — impacts as little code as possible
- **Reuses existing code** — does not create parallel mechanisms
- **Extends existing mechanisms** — if functionality exists elsewhere, the plan extends it rather than creating a new code path
- **Follows CLAUDE.md guidelines** — project-level and user-level
- **Cross-repo dependencies identified** — changes in one repo that affect dependents are accounted for
- **Acceptance criteria coverage** — every AC from the Jira ticket is addressed

**Override knobs:** `QSHIP_PLAN_REVIEW_MODEL` (default `opus[1m]`), `QSHIP_PLAN_REVIEW_EFFORT` (default `high`).

---

## Step 7: Implement (qcode)

**Goal:** Execute the implementation plan step by step, running tests after each change.

### 7.0 Pre-Implementation Memory Search

Before writing any code, search memories for lessons relevant to this implementation:

1. Read `MEMORY.md` index — scan for relevant feedback entries
2. Search for keywords matching the feature area (e.g., "React", "fetchJson", "204", "modal", "Dash", "callback", "enum", "cross-repo", "alias", "catalog", "scope")
3. Apply any relevant lessons — e.g., if building React components, check for "Handle 204 in ALL components"; if making cross-repo API calls, check for "Cross-repo enum casing"

**Write memories during implementation:** If you fix a bug, discover a pattern, or learn something reusable while coding, write a memory file IMMEDIATELY — don't wait for later steps.

### 7.1 Implementation Loop (TDD — Red-Green-Refactor)

**You MUST follow Test-Driven Development for every new function, feature, or bug fix.** The cycle is:

1. **RED** — Write a failing test first
2. **GREEN** — Write the minimal code to make it pass
3. **REFACTOR** — Clean up without adding behavior

For each component in the plan:

1. **Read the plan step** -- understand what files to create/modify
2. **Search for analogous code FIRST** -- before writing any new code, find and read similar implementations in the codebase. Look for analogous TESTS too — match existing test patterns.
3. **Write the failing test FIRST:**
   - Write one minimal test for the behavior you're about to implement
   - Run it and **confirm it fails for the right reason** (e.g., `ImportError`, `AttributeError`, not a syntax error):
     ```bash
     cd <WORKTREE_PATH>/<repo-name> && pytest tests/path/to/test.py::test_name -v
     ```
   - If the test passes without implementation, your test is wrong — it's testing nothing. Fix the test.
4. **Write the minimal implementation** -- following the plan exactly, matching patterns from analogous code. Write ONLY enough code to make the failing test pass.
5. **Run the test again and confirm it passes:**
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && pytest tests/path/to/test.py::test_name -v
   ```
   - If it fails, fix the implementation (not the test) until green.
   - Then run the FULL test suite to ensure nothing else broke:
     ```bash
     cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
     ```
6. **Refactor** -- clean up duplication, improve names, simplify. Stay green (re-run tests after each refactor change).
7. **Repeat** for the next behavior/function in this plan step.

**When TDD does NOT apply** (skip straight to implementation + test verification):
- Pure refactors/renames where existing tests already cover the behavior
- Config changes, import updates, formatting fixes
- Migration files (generated by alembic, not hand-written)

**After all plan steps are implemented, check formatting:**
```bash
cd <WORKTREE_PATH>/<repo-name> && black {{CODEBASE_PATH_PREFIX}}/ && isort {{CODEBASE_PATH_PREFIX}}/ && flake8 {{CODEBASE_PATH_PREFIX}}/
```

### 7.1.1 Batch Checkpoints (Large Tickets)

After the plan is written (Step 5), count the number of tasks in the plan:

- **< 5 tasks:** Implement all tasks, then report (current behavior)
- **5+ tasks:** Enable batch mode:
  1. Implement 3 tasks following the TDD loop above
  2. Commit the batch:
     ```bash
     cd <WORKTREE_PATH>/<repo-name> && git add -A && git commit -m "wip: <TICKET_ID> batch N — <summary of tasks>"
     ```
  3. Report progress: which tasks are done, test results, any blockers
  4. Continue with the next 3 tasks
  5. Repeat until all tasks are complete

Batch checkpoints create save points — if a later batch introduces a regression, you can identify which batch caused it.

### 7.2 Cross-Repo Implementation Order

If multiple repos are affected, implement in dependency order:
1. `{{PRIMARY_REPO_NAME}}` first (it is the dependency for others)
2. dependent repos second (in dependency order)

### Migration handling (within Step 7 — critical)

> Numbered sub-steps inside Step 7 use plain headings (no `7.x` prefix) to avoid colliding with the top-level Steps `7.3 Directory Check` and `7.4 Clean Defensive` further down.

If the plan requires database migrations:

**Rules:**
- **ONE migration file per PR** -- combine all schema changes (new tables, new columns, indexes) into a single migration
- **ALWAYS use `alembic revision --autogenerate`** -- NEVER hand-write or LLM-generate migration files. NO EXCEPTIONS. A `PreToolUse` hook (`enforce-migration-autogenerate.py`) will BLOCK any attempt to Write a file matching `alembic/versions/*.py`. If you cannot run autogenerate, write an `.sh` script with the command and ask the user to run it.
- **`.env` MUST already be in the worktree** — the orchestrator copies it during worktree creation. If it's missing, copy it now: `cp {{CODEBASE_ROOT}}/<repo-name>/.env <WORKTREE_PATH>/<repo-name>/.env`
- **Set PYTHONPATH** if the repo imports a sibling repo in the monorepo
- **Trim unrelated drift** from autogenerate output (dropped indexes, comment changes not related to your PR). A `PostToolUse` hook (`check-drift.py`) will remind you to verify drift after editing migration files.

**Process:**
```bash
# 1. Verify .env exists (should already be copied during worktree creation)
ls <WORKTREE_PATH>/<repo-name>/.env || cp {{CODEBASE_ROOT}}/<repo-name>/.env <WORKTREE_PATH>/<repo-name>/.env

# 2. Write an .sh script for autogenerate (hook blocks direct alembic commands)
cat > <WORKTREE_PATH>/run_autogenerate.sh << 'EOF'
#!/bin/bash
cd <WORKTREE_PATH>/<repo-name>
export $(grep '^DATABASE_URL' .env | head -1)
export PYTHONPATH="<WORKTREE_PATH>/<repo-name>:{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}:$PYTHONPATH"
~/.pyenv/versions/3.11.14/bin/python -m alembic revision --autogenerate -m "<description>"
EOF
chmod +x <WORKTREE_PATH>/run_autogenerate.sh

# 3. Ask user to run: bash <WORKTREE_PATH>/run_autogenerate.sh

# 4. After user runs it, READ the generated migration file
# 5. TRIM unrelated drift using Edit tool (Edit is allowed, Write is blocked)
# 6. Write upgrade script and ask user to run: bash <WORKTREE_PATH>/run_upgrade.sh
```

**If autogenerate fails:**
- Missing `.env` / `DATABASE_URL`: Copy `.env` from main repo (see step 1 above)
- Import errors: Set `PYTHONPATH` to include the worktree path and any sibling repo paths
- Database connection refused: Report the error and STOP — do NOT hand-write a migration
- **NEVER** fall back to writing migration SQL by hand. The autogenerate command MUST succeed.

**Signs of LLM-generated migrations (reject these):**
- Predictable sequential revision IDs (e.g., `a1b2c3d4e5f6`, `b2c3d4e5f6a7`)
- Missing `# ### commands auto generated by Alembic` comments
- Hand-crafted docstrings with implementation notes
- Multiple migration files for changes that should be one migration
- `op.execute()` with raw DDL for tables that should be in the ORM

### Completion check (within Step 7)

After implementing all plan steps:
- Run the full test suite one final time per repo
- Verify all acceptance criteria from the Jira ticket are addressed
- Verify no formatting or linting issues remain

---

## Step 7.3: Directory Organization Check

**Goal:** Verify that all new files are in the correct directories following the project's separation of concerns before any cleanup or review.

### 7.3.1 Run Directory Check

Invoke the `qdirectory` skill:

```
Use the Skill tool:
  skill: "qdirectory"
```

Provide it with context:
- Which files were created or moved during implementation
- The repo structure (api/, services/, repositories/, data_models/)
- The affected repos: `<AFFECTED_REPOS>`

### 7.3.2 Apply Recommendations

For each structural issue identified:
1. Move the file to the recommended location
2. Update all import paths in files that reference it
3. Run tests to confirm nothing broke:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
   ```
4. If moving a file breaks too many imports and tests, note the issue in the review report instead of moving it

---

## Step 7.4: Clean Defensive Code

**Goal:** Remove redundant defensive code (unneeded try/except, redundant null checks) that hides bugs and adds noise.

### 7.4.1 Run Clean Check

Invoke the `qclean` skill:

```
Use the Skill tool:
  skill: "qclean"
```

### 7.4.2 Apply Removals

For each item flagged:
1. Read the full context around the cited location (20+ lines) to confirm the removal is safe
2. Apply the deletion
3. Run tests after each removal:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
   ```
4. If a removal breaks a test, revert that specific deletion and move on

---

---

## ⛔ PHASE 1.5: TRD MIRROR REVIEW + GAP FIX (Opus Sub-Agent)

**Phase 1.5 runs AFTER Phase 1 completes and BEFORE Phase 2 starts.**

This phase catches stubs, TODOs, missing features, and incomplete implementations before the code review begins. It prevents the common failure where Phase 1 sub-agents skip "complex" parts of the TRD and the gaps aren't caught until E2E testing.

### Step 7.45: TRD Mirror Review + Implement Gaps

**Goal:** Line-by-line comparison of every TRD/ticket requirement against the actual code implementation. Fix all gaps found.

#### 7.45.1 Dispatch Opus Mirror Review Agent

The orchestrator dispatches an Opus sub-agent with:

```
Agent(
  model: "opus",
  mode: "bypassPermissions",
  prompt: |
    You are doing a line-by-line mirror review of the TRD/ticket against the
    actual code implementation. Your job is to find GAPS and FIX them.

    ## TRD/Ticket
    <paste full TRD content or Jira ticket description + acceptance criteria>

    ## Code Location
    <worktree paths for all affected repos>

    ## Your Task
    1. Read the FULL TRD/ticket, section by section
    2. For EACH requirement, search the code to verify it's implemented
    3. For each item, report:
       - IMPLEMENTED — code exists and matches TRD
       - PARTIAL — code exists but incomplete (describe what's missing)
       - MISSING — no code found
       - STUBBED — code exists but returns hardcoded/fake values
    4. For every PARTIAL, MISSING, or STUBBED item: IMPLEMENT IT NOW
       - Write the code
       - Write tests
       - Run tests to verify
    5. After all gaps are fixed, run the full test suite
    6. Commit and push all fixes

    DO NOT just report gaps. FIX THEM.
    DO NOT say "this is too complex" or "defer to follow-up". IMPLEMENT IT.
    The TRD is the spec. Every line of it must be implemented.
)
```

#### 7.45.2 Orchestrator Audits Mirror Review Results

After the Opus agent completes:

1. **Read its report** — check for any items still marked PARTIAL, MISSING, or STUBBED
2. **If gaps remain:** dispatch ANOTHER sub-agent to fix them, with specific instructions
3. **If all items are IMPLEMENTED:** Phase 1.5 passes → proceed to Phase 2
4. **Maximum 2 redispatch iterations** for Phase 1.5

#### 7.45.3 Gate Criteria

Phase 1.5 passes when:
- Every TRD requirement is marked IMPLEMENTED
- No stubs, TODOs, or placeholder code remains
- All tests pass after gap fixes
- Code is committed and pushed

---

---

## Phase 2 / 3 / 4 step-ordering preconditions

Phase 2 (Steps 7.5–11.7), Phase 3 (Step 14), and Phase 4 (Steps 12–13, 15) are dispatched by the orchestrator to sub-agents. Use this as the dependency chart — moving to step N+1 requires step N marked DONE in `phase2-progress.md`.

- **Phase 1.5** — per ticket — TRD mirror review + gap fix (Opus sub-agent)
- **Phase 2** — per ticket — static analysis (code review, bug hunting in diffs)
- **Phase 3** — once across ALL tickets — dynamic validation (E2E against running servers)
- **Phase 4** — once after Phase 3 — PR creation, final review, pipeline check

**Phase 2 precondition chain (per ticket):**
- Step 7.5 requires: subagent completed with PIPELINE EXECUTION REPORT
- Step 8 requires: Step 7.5 DONE (and §7.5.3 confirms simplifier suggestions were applied)
- Step 9 requires: Step 8 DONE (and §8.8 wrote `phase2-findings.md`)
- Step 10 requires: Step 9 DONE (raw findings available)
- Step 11 requires: Step 10 DONE (validated findings available)
- Step 11.5 requires: Step 11 DONE — every MUST FIX row in `phase2-findings.md` ticked or moved to `Rejected with rationale`
- Step 11.6 (`/qe2etest`) requires: Step 11.5 DONE
- Step 11.7 (`/qmemory`) requires: Step 11.6 DONE — capture lessons before Phase 3

**Phase 3 precondition (once, across all tickets):**
- Step 14 requires: ALL tickets have completed Phase 2 (Step 11.7 DONE for every ticket)

**Phase 4 precondition (once, after Phase 3):**
- Step 12.0 requires: Step 14 DONE (E2E testing passed; Phase 3 fixes settled)
- Step 12 requires: Step 12.0 DONE — every affected repo has a fresh `phase4-tests-passed.<repo>.flag` file. **Enforced by `require-pre-pr-test-pass.sh` hook on `gh pr create`** — there is no soft path here.
- Step 12.5 requires: Step 12 DONE — PR URL captured for each repo
- Step 12.6 requires: Step 12.5 reported FAIL (skip 12.6 if all-green)
- Step 13 requires: Step 12.5 reported PASS (re-loop through 12.6 until then)
- Step 15 requires: Step 13 DONE (all reviews posted)

**Before moving to step N+1, verify step N is marked DONE in the progress tracker.**

---

## EPIC_MODE skip gate (applies to Steps 7.5 through 11.7)

**If the env var `EPIC_MODE=true` is set in your shell** (check with `echo $EPIC_MODE`), the orchestrator (qshipmaster) is batching Phase 2 review and Phase 3 E2E at the wave level on the merged diff. You MUST skip Steps 7.5, 8.x, 9.x, 10, 11, 11.5, 11.6, and 11.7. Instead:

1. Verify Phase 1 work (steps 1–7) is committed to your ticket branch.
2. Write a one-paragraph summary to `{{STATE_ROOT}}/worktrees/<TICKET>/phase1-summary.md` (what you implemented, which files touched, which AC the impl covers).
3. Touch `{{STATE_ROOT}}/worktrees/<TICKET>/phase1-complete.flag` with the changed-files list (`git diff --name-only <base>..HEAD > .../phase1-complete.flag`).
4. STOP. Do not invoke any of: `/qsimplify`, `/qcheck`, `/qbug`, `/qbcheck`, `/qcheckt`, `/qmigrationdevcheck`, `/qauthtrailingslash`, `/qe2etest`, `/qmanualt`, `/qmemory`, `/qshipcheck`, `/qphase3critic`. Do not dispatch Task subagents named `code-reviewer`, `qcheckt`, `code-simplifier`, `bug-hunter`, `logic-error-detector`, `silent-failure-hunter`, `race-condition-spotter`, `root-cause-tracer`, `edge-case-hunter`, `security-scanner`, or `spec-compliance`. Do not run `pytest tests/` (full suite) — only scoped pytest on files you touched.

The hook `~/.claude/hooks/epic-mode-guard.sh` enforces this deterministically — if you try to dispatch a forbidden subagent or run a forbidden command, the tool call will be blocked with a structured rejection. That's the safety net, but you should not depend on it: follow this gate proactively to avoid wasted iterations.

**Why**: the wave-batch review runs the same Phase 2 + Phase 3 work ONCE on the merged diff covering all tickets in the wave. Doing it per ticket is ~10× more subagent dispatches with no quality gain — the wave-batch catches cross-ticket interactions that per-ticket review cannot. EPIC_MODE compliance saves ~30-60 min per ticket on a typical 6-wave epic.

If `EPIC_MODE` is unset (interactive `/qship {{JIRA_PROJECT_KEY}}-XXX` invocation, not under qshipmaster), continue to Step 7.5 as normal.

---

## Step 7.5: Simplify Code

**⚠️ ORCHESTRATOR-ONLY STEP — Subagents cannot execute this step.**

Subagents do not have access to the Task tool (nested agent spawning is blocked by design in Claude Code). The subagent should mark this step as `[DEFERRED TO ORCHESTRATOR]` in its report. The orchestrator runs this step after the subagent completes implementation.

**Goal:** Simplify and refine all newly written code for clarity, consistency, and maintainability before the review stage.

### 7.5.1 Launch Simplifier Agent (Orchestrator)

For each repo in `<AFFECTED_REPOS>`, get the diff to pass as context:

```bash
cd <WORKTREE_PATH>/<repo-name> && git diff
cd <WORKTREE_PATH>/<repo-name> && git diff --cached
```

Dispatch the code simplifier using the `code-simplifier:code-simplifier` subagent type:

```
Task(
  subagent_type: "code-simplifier:code-simplifier",
  mode: "bypassPermissions",
  description: "Simplify recently modified code",
  prompt: |
    Simplify and refine the recently modified code in this repository for clarity,
    consistency, and maintainability while preserving all functionality.

    Repository path: <WORKTREE_PATH>/<repo-name>
    Focus only on files changed in this diff:
    <paste diff here>

    After simplifying, run tests to confirm nothing broke:
      cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v

    Then run formatting:
      cd <WORKTREE_PATH>/<repo-name> && black {{CODEBASE_PATH_PREFIX}}/ && isort {{CODEBASE_PATH_PREFIX}}/ && flake8 {{CODEBASE_PATH_PREFIX}}/
)
```

If multiple repos are affected, dispatch one agent per repo in a **single message** (parallel).

### 7.5.2 After Simplification

Once the agent(s) return:
1. Verify tests still pass:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
   ```
2. If any tests broke, revert the simplification for the affected file and re-run tests.

### 7.5.3 Apply-suggestions enforcement

The simplifier subagent has Edit/Write tools and **must** apply changes itself, not return a list of suggestions for the orchestrator to apply later. Verify this happened:

```bash
cd <WORKTREE_PATH>/<repo-name> && git diff --stat
cd <WORKTREE_PATH>/<repo-name> && git log --oneline -5
```

**Gate check** — every line below has to be true before proceeding to Step 8 (the simplifier ran in read-only mode is the failure mode this guards against):

- [ ] `git diff` shows non-zero edits since the simplifier dispatch (or simplifier explicitly reported "no simplifications warranted" with file-level reasoning, not a generic "code is fine")
- [ ] If the simplifier returned a written report listing N suggestions, ALL N are reflected in the working tree (open the report, grep each suggestion's file:line against `git diff`)
- [ ] Tests still pass (re-run from 7.5.2)

If the simplifier **listed suggestions but didn't apply them** (common failure when the subagent runs in read-only mode by accident), re-dispatch with explicit edit instructions:

```
Re-dispatch prompt addition:
  "You returned <N> suggestions but the working tree shows zero edits since dispatch.
   Apply every suggestion you listed using Edit/Write tools. Do NOT return a list —
   return a diff. After applying, run tests. If a suggestion breaks a test, revert
   that suggestion only and continue with the rest."
```

Record in `phase2-progress.md`:
```
Step 7.5 Simplify:
  Suggestions returned: <N>
  Suggestions applied:  <N>   ← MUST equal the above
  Diff stats:           <git diff --stat output>
```

---

## Step 8: Code Review (qcheck)

**Goal:** Perform a thorough dual-agent code review of all changes, combining comprehensive production readiness checks with confidence-scored guideline compliance.

### 8.0 Complexity Tier (gates how many reviewers + bug hunters fan out)

Before §8.1, classify the diff and pick a tier. Rationale: 5-tier complexity routing is industry-standard for multi-agent orchestration ([ClaudeFast Code Kit](https://claudefa.st/blog/guide/agents/task-distribution), [Anthropic Managed Agents](https://claude.com/blog/new-in-claude-managed-agents)) — running full fan-out on a doc fix wastes 60–90% of the token budget and adds zero signal. Routing trivial work to fewer specialists is the most reliable token optimization for agentic pipelines (see also [Token Optimization 2026](https://www.obviousworks.ch/en/token-optimization-saves-up-to-80-percent-llm-costs/)).

**Compute the tier from the diff** (per repo, then take the MAX across repos):

```bash
cd <WORKTREE_PATH>/<repo-name>
LOC=$(git diff <BASE_BRANCH>..HEAD --shortstat | awk '{print $4+$6}')
FILES=$(git diff <BASE_BRANCH>..HEAD --name-only | wc -l)
MIGRATIONS=$(git diff <BASE_BRANCH>..HEAD --name-only | grep -c "alembic/versions/")
AUTH=$(git diff <BASE_BRANCH>..HEAD --name-only | grep -cE "auth|oauth_provider|permission|rbac|/middleware/")
ROUTES=$(git diff <BASE_BRANCH>..HEAD --name-only | grep -cE "/api/|/routers/|/endpoints/")
SECURITY=$(git diff <BASE_BRANCH>..HEAD --name-only | grep -cE "secret|credential|token|crypto|password|hash")
DOC_ONLY=$(git diff <BASE_BRANCH>..HEAD --name-only | grep -vcE "\.(md|rst|txt)$")
```

**Tier table** — pick the FIRST row that fully matches:

| Tier | Name | Signals | Step 8 fan-out | Step 9 fan-out | Notes |
|---|---|---|---|---|---|
| **T1** | Trivial | LOC ≤ 20, FILES ≤ 2, MIGRATIONS=0, AUTH=0, ROUTES=0, SECURITY=0, no behavior change (typos, comments, doc-only, dep-bump) | **0 reviewers** | **0 bug hunters** | Step 10 qbcheck still runs against the diff itself — gate stays in place. |
| **T2** | Small | LOC ≤ 100, FILES ≤ 4, MIGRATIONS=0, AUTH=0, SECURITY=0, single repo, no public API contract change | **1 reviewer** (production correctness) | **2 bug hunters** (logic-error + edge-case) | Skip qauthtrailingslash and qmigrationdevcheck (no relevant surface). |
| **T3** | Medium | LOC ≤ 500, FILES ≤ 12, single repo, no schema migration | **2 reviewers** (production + guidelines) | **3 bug hunters** (logic-error + edge-case + data-flow) | Run qauthtrailingslash only if ROUTES > 0. |
| **T4** | Complex (default) | Anything not matching T1–T3, OR MIGRATIONS > 0 OR AUTH > 0 OR cross-repo OR SECURITY > 0 | **3 reviewers** (production + guidelines + spec) | **5 bug hunters** (full swarm) | Full §8.5.1 qmigrationdevcheck and §8.6.5 qauthtrailingslash always required. |

**Auto-escalation overrides** — promote to T4 regardless of size:
- Any change under `auth/`, `oauth_provider/`, `permissions/`, `rbac/`, or `middleware/`
- Any change to `requirements*.txt` / `package.json` lockfiles touching crypto / auth libs
- Any change inside `alembic/versions/` (migration safety always needs full review)
- Any cross-repo change (≥ 2 repos in `<AFFECTED_REPOS>`)
- User explicitly set `QSHIP_FORCE_TIER=T4` in `USER_NOTE.md`

**Record the tier in `phase2-progress.md` BEFORE dispatching reviewers:**
```
Step 8.0 Complexity Tier:  T<1|2|3|4>
  Signals: LOC=<n> FILES=<n> MIGRATIONS=<n> AUTH=<n> ROUTES=<n> SECURITY=<n>
  Fan-out: <N reviewers>, <M bug hunters>
  Rationale: <one line — e.g., "single-file UI bugfix in RecordManagement.jsx, no auth/migration/route changes">
```

The PENDING-row labels in `phase2-progress.md` for unused agents (e.g. for T2: `8 Review Agent 2 (guidelines)`, `8 Review Agent 4 (spec)`) MUST be marked `SKIPPED [tier T2]` with the same one-line rationale — the Stop hook treats `SKIPPED [tier ...]` rows as satisfied, but plain `PENDING` rows still block.

### 8.1 Memory Lookup

```
Use mcp__basic-memory__search_notes with:
- query: [keywords from the code being reviewed -- e.g., "code review", "testing", "error handling"]
- search_type: "semantic"
- page_size: 10
```

### 8.2 Gather Changes & Context

For each repo in `<AFFECTED_REPOS>`:
```bash
cd <WORKTREE_PATH>/<repo-name> && git diff
cd <WORKTREE_PATH>/<repo-name> && git diff --cached
```

Get git SHAs for the review range:
```bash
cd <WORKTREE_PATH>/<repo-name> && BASE_SHA=$(git merge-base HEAD develop) && HEAD_SHA=$(git rev-parse HEAD)
```

Read the review guidelines:
- Project-level: `<WORKTREE_PATH>/CLAUDE.md`
- User-level: `~/.claude/CLAUDE.md`

Summarize what was implemented (from the diff, recent commits, and plan file if it exists).

### 8.3 Launch Parallel Review Agents

**⚠️ Agents 1 and 2 are ORCHESTRATOR-ONLY — subagents cannot dispatch them.**

Subagents do not have access to the Task tool. The subagent should:
- Invoke Agent 3 (qcheckt) via the Skill tool (this works)
- Mark Agents 1 and 2 as `[DEFERRED TO ORCHESTRATOR]` in its report
- The orchestrator runs Agents 1 and 2 after the subagent completes

Deploy Agents 1 and 2 simultaneously in a **single message** with two Task tool calls (orchestrator only):

**Agent 1: Superpowers Code Reviewer** (`superpowers:code-reviewer` subagent type)

```
Prompt: "You are reviewing code changes for production readiness.
Review: <WHAT_WAS_IMPLEMENTED>
Compare against: <PLAN_OR_REQUIREMENTS>
Git Range: Base: <BASE_SHA>, Head: <HEAD_SHA>
Run: git diff --stat <BASE_SHA>..<HEAD_SHA> and git diff <BASE_SHA>..<HEAD_SHA>

Check: code quality (separation of concerns, error handling, DRY, edge cases),
architecture (design decisions, scalability, performance, security),
testing (tests test logic not mocks, edge cases, integration tests),
requirements (all plan requirements met, no scope creep),
production readiness (migrations, backward compatibility, documentation),
UUID resolution surface (see below).

UUID resolution surface (NEW — post-{{JIRA_PROJECT_KEY}}-EX12):
For any new UI surface rendering a UUID-typed field via a resolve*Name /
resolve*Value helper, verify:
  (a) the render is gated on resolver.ready — the resolver hook family
      exposes this attribute (see src/components/shared/entityLookup.js:121
      and the sibling node / organization / attribute hooks);
  (b) the loading state renders a Mantine <Skeleton> matching the
      canonical convention used by ResolvedRefCell.jsx and
      ResolvedSummaryView.jsx (the only acceptable shape in this codebase);
  (c) the fallback when .ready === true AND resolver(id) === null does
      NOT introduce a truncated-UUID placeholder ('Entity 00000000...').
      Convention is: render the raw UUID at that point. Truncated
      placeholders are NOT the codebase convention — they are a finding;
  (d) if the surface has a Playwright test, the test runs against the
      LIVE lookup endpoint OR uses real hooks with CORS bypass
      (mock-aliases removed + chromium --disable-web-security).
      Mocked-hook Playwright runs are insufficient.

Mark as a CRITICAL finding when the diff has 'resolver(id) || id'
(raw-UUID fallback) WITHOUT a .ready / Skeleton gate AND the existing
tests for the file mock the resolver. That combination guarantees a UI
leak in any environment where the lookup endpoint is unreachable AND no
test will catch it — exactly the {{JIRA_PROJECT_KEY}}-EX12 failure mode.

Output: Strengths, Issues (Critical/Important/Minor with file:line), Recommendations,
Assessment: Ready to merge? [Yes/No/With fixes]"
```

**Agent 2: Feature-Dev Code Reviewer** (`feature-dev:code-reviewer` subagent type)

```
Prompt: "Review code changes for bugs, logic errors, security vulnerabilities,
code quality issues, and adherence to project conventions.
Git range: <BASE_SHA>..<HEAD_SHA>
Run: git diff <BASE_SHA>..<HEAD_SHA>
Read CLAUDE.md at the repo root and ~/.claude/CLAUDE.md for guidelines.

Focus on: CLAUDE.md compliance, bug detection (logic errors, null handling,
race conditions, security), code quality (duplication, error handling, test coverage),
UUID resolution surface (see below).

UUID resolution surface (NEW — post-{{JIRA_PROJECT_KEY}}-EX12):
For any new UI surface rendering a UUID-typed field via a resolve*Name /
resolve*Value helper, verify:
  (a) the render is gated on resolver.ready — the resolver hook family
      exposes this attribute (see src/components/shared/entityLookup.js:121
      and the sibling node / organization / attribute hooks);
  (b) the loading state renders a Mantine <Skeleton> matching the
      canonical convention used by ResolvedRefCell.jsx and
      ResolvedSummaryView.jsx (the only acceptable shape in this codebase);
  (c) the fallback when .ready === true AND resolver(id) === null does
      NOT introduce a truncated-UUID placeholder ('Entity 00000000...').
      Convention is: render the raw UUID at that point. Truncated
      placeholders are NOT the codebase convention — they are a finding;
  (d) if the surface has a Playwright test, the test runs against the
      LIVE lookup endpoint OR uses real hooks with CORS bypass
      (mock-aliases removed + chromium --disable-web-security).
      Mocked-hook Playwright runs are insufficient.

Mark as a CRITICAL finding when the diff has 'resolver(id) || id'
(raw-UUID fallback) WITHOUT a .ready / Skeleton gate AND the existing
tests for the file mock the resolver. That combination guarantees a UI
leak in any environment where the lookup endpoint is unreachable AND no
test will catch it — exactly the {{JIRA_PROJECT_KEY}}-EX12 failure mode.

Rate each issue 0-100 confidence. Only report issues with confidence >= 80.
Group by severity (Critical vs Important). For each: description, confidence score,
file:line, guideline reference or bug explanation, concrete fix."
```

**Agent 3: Tests Reviewer** (invoke `qcheckt` skill — subagent CAN do this)

```
Use the Skill tool:
  skill: "qcheckt"
```

This reviews every test added or edited in the diff for:
- Testing best practices (testing logic not mocks, proper assertions)
- Proper test isolation and use of fixtures from conftest.py
- Meaningful test names and descriptions
- Structure and data integrity verification

**Agent 4: Spec Compliance Reviewer** (ORCHESTRATOR-ONLY — requires Task tool)

```
Task(
  subagent_type: "general-purpose",
  mode: "bypassPermissions",
  description: "Spec compliance review for <TICKET_ID>",
  prompt: |
    You are a spec compliance reviewer. Your ONLY job is to verify that the implementation
    matches the Jira ticket's acceptance criteria. You are NOT reviewing code quality —
    other agents handle that.

    ## Jira Ticket
    Ticket: <TICKET_ID>
    Summary: <TICKET_SUMMARY>
    Acceptance Criteria:
    <ACCEPTANCE_CRITERIA from Step 1>

    ## Implementation Diff
    <paste diff here>

    ## Your Task
    For EACH acceptance criterion, determine:
    - AC MET: The diff clearly implements this criterion
    - AC PARTIALLY MET: Some aspects implemented, others missing (specify what's missing)
    - AC NOT MET: No evidence of this criterion in the diff

    Output a table:
    | # | Acceptance Criterion | Status | Evidence / Gap |
    |---|---------------------|--------|----------------|

    Then a summary:
    - Overall: PASS (all ACs met) / FAIL (any AC not met) / PARTIAL (some gaps)
    - Missing items that must be addressed before merge

    ## ALSO: UUID resolution surface check (NEW — post-{{JIRA_PROJECT_KEY}}-EX12)
    Even though this is a spec-compliance reviewer, you MUST also flag any new
    UI surface in the diff that renders a UUID-typed field via a resolve*Name /
    resolve*Value helper. Verify:
      (a) the render is gated on resolver.ready (the resolver hook family
          exposes this — see src/components/shared/entityLookup.js:121);
      (b) the loading state renders a Mantine <Skeleton> matching the
          canonical convention used by ResolvedRefCell.jsx and
          ResolvedSummaryView.jsx — the only acceptable shape in this codebase;
      (c) the fallback when .ready === true AND resolver(id) === null does
          NOT introduce a truncated-UUID placeholder. Convention: render
          the raw UUID at that point. Truncated placeholders are a finding;
      (d) if the surface has a Playwright test, the test runs against
          the LIVE lookup endpoint OR uses real hooks with CORS bypass
          (mock-aliases removed + chromium --disable-web-security).
          Mocked-hook Playwright runs are insufficient.
    Mark as a CRITICAL finding when the diff has 'resolver(id) || id'
    (raw-UUID fallback) WITHOUT a .ready / Skeleton gate AND the existing
    tests for the file mock the resolver. Rationale: UUID-leaks ship as an
    AC violation ("display the entity's name" becomes "display the entity's
    id" in production), so this IS a spec compliance concern even though
    the surface form is code quality.
)
```

Spec compliance findings feed into Step 8.8 synthesis:
- **AC NOT MET** items → MUST FIX (implementation is incomplete)
- **AC PARTIALLY MET** items → SHOULD FIX (evaluate whether the gap is critical)
- **AC MET** items → no action needed

### 8.4 Analogous Code Check (CRITICAL -- Manual)

**While agents are running, perform this check yourself.** This requires deep codebase knowledge and semantic search that agents cannot do.

1. **Search for analogous code** using semantic search (`mcp__claude-context-local__search_codebase`) + grep/glob
2. **Compare line-by-line** with analogous implementations:
   - SQL queries: all WHERE clauses, JOINs, filters (`is_active`, `tenant_id`)
   - Method signatures: parameters, thresholds, return types
   - Error handling patterns
   - Data flow and structure
3. **Flag any deviation** from analogous code -- explain why it differs
4. **Check for parallel code paths** -- if new mechanisms were added, verify no existing mechanism already does the same thing
5. **Ask "where does this already happen?"** -- search for existing similar functionality

### 8.5 Alembic Migration Validation (CRITICAL)

If the diff includes migration files:

1. **Max one migration file per PR** -- if there are multiple, they must be combined into one
2. **Must be autogenerated** -- verify by checking for:
   - `# ### commands auto generated by Alembic - please adjust! ###` comment present
   - Random-looking revision ID (not sequential hex like `a1b2c3d4e5f6`)
   - No hand-crafted docstrings with implementation notes
3. **If migration looks LLM-generated:** delete it and regenerate with `alembic revision --autogenerate`
4. **Unrelated drift trimmed** -- autogenerate often picks up pre-existing drift (dropped indexes, comment changes); these must be removed

### 8.5.1 Migration Chain Validator (`/qmigrationdevcheck`)

**Required when the diff includes ANY file under `*/alembic/versions/`** (or the repo's migrations dir). Runs alongside §8.5 — §8.5 checks file content, this checks chain integrity.

```
Use the Skill tool:
  skill: "qmigrationdevcheck"
  args: <WORKTREE_PATH>/<repo-name>
```

Catches: branched chains, missing `down_revision`, duplicate revision IDs, head divergence vs `develop`, missing entries in cross-schema chains (between your repos' schemas).

**Gate check** — if `/qmigrationdevcheck` reports any of:
- "BRANCHED CHAIN" → MUST FIX before Phase 3 (will break `migrate-tenants`)
- "MISSING DOWN_REVISION" → MUST FIX
- "HEAD DIVERGENCE FROM DEVELOP" → re-base your migration on the latest develop head and re-run autogenerate

…feed those findings into §8.8 as **MUST FIX** items. Do not proceed to §9 until they're recorded.

### 8.6 Cross-Branch Integration Review (Epic Waves Only)

**When to run:** When the orchestrator is running Steps 8-13 for an epic wave where ANY of these are true:
- Stories in the wave touch **2+ different repos** (cross-repo)
- Stories **stack on a previous wave's branch** in the same repo (cross-branch)
- Manual **cherry-picks or cross-branch integrations** were done by the orchestrator

Skip for standalone single-repo, single-branch tickets.

See SKILL.md §E4.2 for full details. The orchestrator:

1. Gathers combined diffs from ALL related branches (current wave + dependency branches)
2. Builds a combined context document with labeled headers (DEPENDENCY vs CURRENT)
3. Dispatches 3 parallel integration-aware agents:
   - **Contract & Schema Reviewer** — API contracts, FK references, schema alignment, stacked branch coherence
   - **Data Flow Tracer** — data consistency between branches/repos (JSONB keys, ID resolution, null handling)
   - **Dependency & Ordering Checker** — ordering constraints, missing tables/columns, stale references, migration chains
4. Synthesizes findings and fixes MUST FIX issues before PR creation
5. Includes integration findings in the Step 8.8 synthesis

**Why this matters:** Single-story reviewers cannot see cross-branch or cross-repo integration issues. Examples:
- Repo A changes an endpoint path, repo B still calls the old path — neither reviewer catches it
- Wave 1 branch renames a column, Wave 2 stacked branch still references the old name
- JSONB keys written by one branch don't match the keys read by another

### 8.6.5 Trailing-Slash / 307 Redirect Audit (`/qauthtrailingslash`)

**Required when the diff includes ANY new or modified FastAPI route, router prefix, or React `fetchJson` call site.** This is the #1 source of cross-origin auth-stripping bugs in {{COMPANY_SLUG}} (see memory: "Cross-origin 307 drops Authorization") — POST/PUT to a route without the trailing slash gets 307-redirected; browsers strip the `Authorization` header on cross-origin redirects → silent 401 → empty UI.

```
Use the Skill tool:
  skill: "qauthtrailingslash"
  args: <WORKTREE_PATH>/<repo-name> (or comma-separate if multi-repo diff)
```

Findings feed into §8.8 as **MUST FIX** (these are real prod bugs, not stylistic).

Skip ONLY if the diff has zero changes to: API routers, route decorators, `fetchJson`/fetch URLs, or `axios` base URLs. When in doubt, run it — the skill is fast.

### 8.7 Documentation Staleness

Check if `CLAUDE.md` or `docs/ARCHITECTURE.md` need updating after structural changes (new files, moved code, renamed modules).

### 8.8 Synthesize Findings

After ALL agents return, combine findings from **every** review source.

**Universal no-drop rule.** No finding from ANY source may be silently omitted, downgraded, or merged-away. Every row from every source below appears verbatim in the unified list. To dismiss one, it must be moved (not deleted) to a `## Rejected (with rationale)` section with a one-line concrete reason. "Looks fine", "out of scope", "not critical" are NOT valid rationales — only verifiable claims like "false positive — flagged X but actual code does Y, see file:line".

**Mandatory sources (every one MUST be represented in the unified list — DO NOT DROP applies to all):**

| Source | Step | Where findings live |
|--------|------|---------------------|
| Code Simplifier | 7.5 | Diff already applied — verify via `git diff` per §7.5.3 |
| Production Readiness Reviewer (Agent 1) | 8.3 | Agent return value |
| Guidelines Compliance Reviewer (Agent 2) | 8.3 | Agent return value |
| Tests Reviewer (qcheckt, Agent 3) | 8.3 | Skill output |
| Spec Compliance Reviewer (Agent 4) | 8.3 | Agent return value |
| Analogous Code Check | 8.4 | Manual notes |
| Migration Validator (qmigrationdevcheck) | 8.5.1 | Skill output |
| Cross-Branch Integration | 8.6 | Agents 1-3 from §E4.2 |
| Trailing-Slash Audit (qauthtrailingslash) | 8.6.5 | Skill output |
| Documentation Staleness | 8.7 | Manual notes |

For each source, copy its findings into the unified list verbatim. If a source returned "no findings", record that explicitly: `<source>: 0 findings` — never silently omit the source. The historical failure modes are dropping qcheckt findings as "test-only", treating simplifier suggestions as "informational", or quietly swallowing low-severity Agent-1 notes — these all end here, equally, for every source.

Then:

1. **Deduplicate** -- multiple agents may flag the same issue; merge overlapping findings keeping the more detailed description
2. **Categorize** the unified list:
   - **MUST FIX** -- Critical from any agent, analogous code violations, redundant mechanisms, qauthtrailingslash hits, migration-chain breaks, every qcheckt finding tagged "missing assertion" / "test mocks the SUT" / "no test for new branch"
   - **SHOULD FIX** -- Important from any agent, documentation gaps, qcheckt style/naming findings
   - **NOTE** -- Minor issues, observations

3. **Persist the unified list to `<WORKTREE_PATH>/phase2-findings.md`** with this exact structure (Step 11 reads this file):
   ```
   # Phase 2 Findings — <TICKET_ID>

   ## MUST FIX
   - [ ] (source: qcheckt) test_foo.py:42 — assertion checks mock not behavior
   - [ ] (source: qauthtrailingslash) routes/v1/entities.py:18 — POST without trailing slash
   - [ ] (source: Agent 1) services/x.py:120 — race condition on shared state
   ...

   ## SHOULD FIX
   - [ ] ...

   ## NOTE
   - [ ] ...
   ```
   The checkbox per-row is what Step 11 ticks off as it applies fixes. **No row may be silently deleted** — to dismiss one, it must be moved to a `## Rejected (with rationale)` section with a one-line reason.

---

## Step 9: Bug Hunt (qbug)

**⚠️ ORCHESTRATOR-ONLY STEP — Subagents cannot execute this step.**

Subagents do not have access to the Task tool (nested agent spawning is blocked by design in Claude Code). The subagent should mark this step as `[DEFERRED TO ORCHESTRATOR]` in its report. The orchestrator runs this step after the subagent completes implementation.

**Goal:** Hunt for bugs in the changes using parallel specialized agents.

### 9.1 Gather Changes (Orchestrator)

For each repo in `<AFFECTED_REPOS>`:
```bash
cd <WORKTREE_PATH>/<repo-name> && git diff
cd <WORKTREE_PATH>/<repo-name> && git diff --cached
```

### 9.2 Launch Parallel Hunter Agents (Orchestrator)

Deploy 5 specialized agents simultaneously using the **Task tool** (all in a single message with multiple Task calls):

1. **root-cause-tracer**
   ```
   Prompt: "Analyze this diff for potential root-cause issues. Trace any risky code paths backward through the call chain. Look for places where the new code might ORIGINATE errors that manifest elsewhere. Diff: [paste diff]"
   ```

2. **silent-failure-hunter**
   ```
   Prompt: "Search this diff for hidden error suppression: catch blocks that swallow errors, fallbacks that mask problems, empty exception handlers, API calls without error checking, silent data loss. Diff: [paste diff]"
   ```

3. **logic-error-detector**
   ```
   Prompt: "Analyze conditional logic in this diff for: off-by-one errors, inverted conditions, missing null checks, incorrect boolean operators, wrong comparisons, type coercion issues. Diff: [paste diff]"
   ```

4. **edge-case-hunter**
   ```
   Prompt: "Check this diff for untested edge cases: null/empty inputs, boundary values, empty collections, type mismatches, precision loss, truncation, unicode handling.

   ALSO check for UUID-leak edge cases (NEW — post-{{JIRA_PROJECT_KEY}}-EX12). For any new UI
   surface rendering a UUID-bearing field (subject_id, node_id,
   organization_id, attribute_value_id, policy_id, etc.) — typically routed
   through a resolve*Name / resolve*Value helper:
     - {{PRIMARY_REPO_NAME}} unreachable / 401 the external auth provider / CORS preflight failure / network
       partition — does the user see raw UUIDs, or does the resolver.ready
       gate hold the render in a <Skeleton> state? (Canonical pattern: see
       ResolvedRefCell.jsx and ResolvedSummaryView.jsx.)
     - The org has more entities / nodes than the lookup hook's PAGE cap
       (default 500 in src/components/shared/entityLookup.js:20) — are
       out-of-page IDs still rendered safely (Skeleton or raw UUID), or
       does the UI flash a half-loaded state?
     - Cross-tenant cache collision *(multi-tenant apps)* — viewing tenant
       B's policy while tenant A's resolver cache is still loaded in memory —
       does the resolver return the wrong name, or a stale UUID fallback?
     - Empty-string resolver return vs null — does 'resolver(v) || v'
       treat '' as 'no result' and render the raw UUID, or does an empty
       string skip the fallback and render nothing?
     - Truncated-UUID placeholders ('Entity 00000000...') — flag any
       introduction of these as a finding. The codebase convention is
       <Skeleton> while loading, raw UUID after .ready === true; NOT
       a truncated placeholder.

   Diff: [paste diff]"
   ```

5. **race-condition-spotter**
   ```
   Prompt: "Analyze this diff for concurrency bugs: shared mutable state, async timing issues, missing locks, order dependencies, database transaction issues. Diff: [paste diff]"
   ```

### 9.3 Collect Raw Findings

After all agents return:
1. Collect all findings
2. Deduplicate overlapping issues
3. Categorize by severity (Critical / High / Medium / Low)

**IMPORTANT: Do NOT act on these findings yet.** Pass the raw findings through Steps 9.5 + 9.6 (dedupe + ranking) before Step 10 (qbcheck).

Store the raw findings list as `<QBUG_RAW_FINDINGS>`.

---

## Step 9.5: Cross-Agent Deduplication + Convergence Boost

**Goal:** Collapse duplicate findings emitted by multiple bug-hunter agents on the same site, and use cross-agent agreement as a confidence signal. Per [PatchIsland-style two-phase deduplication](https://arxiv.org/html/2510.09721v3) — multiple agents flagging the same `(file, line, class)` is *signal*, not noise.

**Algorithm:**

1. **Group key:** `(normalized_file_path, line_number, attack_angle_class)` where `attack_angle_class` collapses related angles (e.g., `null-deref` from logic-error-detector and edge-case-hunter merge; `race` from race-condition-spotter stays separate).
2. **Within each group:**
   - Merge claim text (keep the most specific).
   - Take MAX severity across reporters.
   - Set `convergence = N` where N = number of distinct agents that flagged this site.
   - **Convergence boost:** if `N ≥ 2`, increase severity by 1 step (S3→S2, S2→S1; cap at S1).
   - **Confidence floor:** if `N ≥ 3`, force confidence to at least C2 (multiple independent flagges are strong signal).
3. **Output:** deduplicated list of findings, each annotated with `convergence: N/<TOTAL_HUNTERS>` and the agent names that converged.

Store as `<QBUG_DEDUPED_FINDINGS>`. Record:
```
Step 9.5 Dedupe:  Raw: <X>  →  Deduped: <Y>  →  Convergence boosts: <Z>
  Top convergence sites:
    - <file>:<line> flagged by <N>/<TOTAL> agents (<list>)
    - …
```

---

## Step 9.6: Confidence-Weighted Top-K Filter

**Goal:** Cut qbcheck token spend by sending only the highest-signal findings, ranked by `severity × confidence × convergence`. Per [Confidence-Improved Self-Consistency (CISC), ACL 2025](https://aclanthology.org/2025.findings-acl.1030.pdf) — confidence-weighted aggregation needs ~46% fewer samples than naive consensus to reach the same accuracy.

**Algorithm:**

1. Score each finding from `<QBUG_DEDUPED_FINDINGS>`:
   ```
   severity_weight  = {S1: 3, S2: 2, S3: 1}[severity]
   confidence_weight = {C1: 3, C2: 2, C3: 1}[confidence]
   convergence_weight = min(convergence, 3)
   score = severity_weight * confidence_weight * convergence_weight
   ```
2. Sort findings by score descending.
3. Apply top-K cap based on §8.0 complexity tier:
   - T1: K = 0 (no qbug, no findings)
   - T2: K = 10
   - T3: K = 20
   - T4: K = 30
4. Findings below the cut are NOT discarded — they go to `<QBUG_TAIL_FINDINGS>` and appear in the final report under "Tail findings (not validated by qbcheck)" so reviewers can see them, but qbcheck doesn't burn tokens on them.

Store the top-K as `<QBUG_FINDINGS>` (this is what Step 10 consumes). Record:
```
Step 9.6 Top-K filter:  Sent to qbcheck: <K>  Tail (unvalidated): <T>
  Top 3 by score:
    - <file>:<line> score=<n> sev=<S> conf=<C> conv=<N>
    - …
```

---

## Step 10: Bug Validation (qbcheck)

**Goal:** Critically validate qbug findings to filter out false positives, overthinking, and overstated issues. Only validated bugs get fixed.

### 10.1 Verification Protocol

For EACH finding in `<QBUG_RAW_FINDINGS>`:

#### 10.1.1 Read the Actual Code

**DO NOT trust the qbug summary.** Read 20+ lines of context around each cited location. Trace the actual control flow.

#### 10.1.2 Ask Critical Questions

1. **Can this code path actually execute?** Check guards, conditions, early returns
2. **Under what conditions?** Default config? Custom settings? Rare edge cases?
3. **What does the code actually do?** Not what qbug claims
4. **Is there a log message?** "Silent" often isn't silent

#### 10.1.3 Categorize Each Finding

| Category | Criteria | Action |
|----------|----------|--------|
| **Real Bug** | Incorrect behavior under normal conditions | Fix it |
| **Valid but Overstated** | Real but only in edge cases/custom configs | Document, maybe fix |
| **False Positive** | Analysis was wrong; code is correct | Reject |
| **Overthinking** | Technically possible but practically irrelevant | Reject |
| **Not a Bug** | Style issue, not runtime behavior | Reject |

### 10.2 Common False Positive Patterns

Watch for these patterns that are often wrong:

1. **"Silent fallback"** -- Check if there's actually a log message
2. **"Dead code can execute"** -- Verify guards don't prevent the condition
3. **"Edge case X causes Y"** -- Does this happen in production?
4. **"Type annotation wrong"** -- Python doesn't enforce types at runtime
5. **"Existing code bug"** -- Was this changed in this session, or pre-existing?
6. **"Boundary condition"** -- Is the difference meaningful in practice?

### 10.3 Produce Validated Bug Report

Create a summary table of all findings:

```
| # | qbug Finding | qbug Severity | Verdict | Actual Severity | Action |
|---|-------------|---------------|---------|-----------------|--------|
| 1 | [finding] | Critical | REAL BUG | Critical | Fix |
| 2 | [finding] | High | FALSE POSITIVE | None | Reject |
| 3 | [finding] | Medium | OVERTHINKING | None | Reject |
```

Store the validated findings (only those with verdict **Real Bug** or **Valid but Overstated** marked for fix) as `<VALIDATED_BUG_FINDINGS>`.

Store the full validation table as `<BUG_VALIDATION_SUMMARY>` for the completion report.

**The goal is ACCURACY, not bug count.** A good validation rejects 30-50% of automated findings as false positives or overthinking.

---

## Step 11: Fix Issues

**Goal:** Fix validated issues from Step 8 (Code Review) and Step 10 (Bug Validation). Do NOT fix rejected qbug findings.

### 11.0 Memory Check Before Fixing

Search memories for patterns related to the bugs you're about to fix. Common lessons that prevent introducing new bugs:
- "Handle 204 in ALL components" — if fixing an API helper, grep for ALL copies
- "Cross-repo enum casing" — if fixing API calls between services
- "Edit modal load nested data" — if fixing modal data loading
- "Dash Store global scope" — if fixing callback errors

**After fixing each bug**, evaluate: is this lesson reusable? If yes, write a memory file immediately via `/qmemory` or directly to the memory directory.

### 11.1 Prioritize Fixes

1. **Read `<WORKTREE_PATH>/phase2-findings.md`** — this file is the canonical input from Step 8.8. Every unchecked `MUST FIX` row is mandatory work for this step, regardless of source. **Do not selectively pick.** The universal no-drop rule from §8.8 applies here: no row may be silently skipped. Historical failure modes that all end here:
   - qcheckt findings dropped as "test-only" (tests mask real bugs via false-green CI)
   - Simplifier suggestions treated as "informational" (they're often dead-code / duplicated-logic flags)
   - Agent-1/Agent-2 low-severity notes swallowed (low-severity ≠ ignorable)
   - qauthtrailingslash hits dismissed as "style" (they're real prod auth-strip bugs)
   - qmigrationdevcheck warnings deferred (they break `migrate-tenants`)
   - Cross-branch integration findings ignored as "the other ticket's problem" (epic merge problems are this ticket's problem if your branch is the dependency)
2. Combine those `MUST FIX` rows with Step 10's `<VALIDATED_BUG_FINDINGS>` (Real Bugs and Valid but Overstated marked for fix)
3. Order by severity and dependency (fix root causes before symptoms)
4. Append `SHOULD FIX` rows that are cheap to address now (under 10 lines of change). Defer the rest with explicit notes.

**Closure contract for this step (gating):**

After fixes, every `MUST FIX` row in `phase2-findings.md` MUST be either:
- **Ticked** (`- [x]`) with a commit hash + file:line proving the fix landed, OR
- **Moved to a `## Rejected (with rationale)` section** with a concrete reason (e.g., "false positive — qcheckt flagged the mock as the SUT but it's a fixture; verified by reading conftest.py:34")

Step 11.5 reads this file as part of the verification gate. Any unticked + un-rejected MUST FIX row blocks Phase 3.

### 11.2 Fix Loop (Systematic Debugging)

For each issue, follow the 4-phase systematic debugging process. Do NOT guess-and-fix.

**Phase 1: Root Cause Investigation**
1. Re-read the relevant code (do NOT rely on memory -- always re-read current state, 20+ lines of context)
2. Reproduce the issue: write a failing test that demonstrates the bug
3. Trace backward: where does the incorrect value/behavior originate?

**Phase 2: Pattern Analysis**
4. Search for analogous code that handles the same pattern correctly
5. Compare your code against the working reference line-by-line
6. Identify the specific divergence that causes the bug

**Phase 3: Hypothesis + Smallest Fix**
7. Form ONE specific hypothesis about the root cause
8. Apply the SMALLEST possible fix (one line if possible)
9. Run the failing test to verify the fix:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && pytest tests/path/to/test.py::test_name -v
   ```

**Phase 4: Verify No Regressions**
10. Run the full test suite:
    ```bash
    cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
    ```
11. Verify the fix resolves the issue without introducing new problems

**3-Fix Limit Rule:** If 3 fix attempts fail for the same bug, STOP. You are likely misidentifying the root cause. Re-investigate from Phase 1 with fresh eyes, or escalate to the user with:
```
STUCK on bug: <description>
Attempted fixes:
  1. <fix 1> — failed because <reason>
  2. <fix 2> — failed because <reason>
  3. <fix 3> — failed because <reason>
Root cause hypothesis: <current best guess>
Need help: <specific question>
```

### 11.3 Re-check Formatting

After all fixes:
```bash
cd <WORKTREE_PATH>/<repo-name> && black {{CODEBASE_PATH_PREFIX}}/ && isort {{CODEBASE_PATH_PREFIX}}/ && flake8 {{CODEBASE_PATH_PREFIX}}/
```

### 11.4 Final Test Run

Run the complete test suite one final time per affected repo:
```bash
cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
```

If any tests fail, investigate and fix before proceeding.

---

## Step 11.5: Verification Before PR (CRITICAL GATE)

**⚠️ ORCHESTRATOR-ONLY STEP — runs after Step 11 fixes are complete.**

**Goal:** Prove with fresh evidence that all tests pass and code is clean BEFORE proceeding to Phase 3 (E2E testing). No claims without proof.

**This is a hard gate. If verification fails, Phase 3 is BLOCKED.**

### 11.5.0 Devin-style self-critique (runs FIRST)

Before running the fresh test or formatter, the orchestrator MUST explicitly reason through this self-critique (Devin leaked prompt, verbatim):

> Before reporting completion to the user, critically examine your work so far and ensure that you completely fulfilled the user's request — such as linting and/or testing. For tasks that require modifying many locations in the code, verify that you successfully edited all relevant locations before telling the user that you're done.

Answer these questions in the phase2-progress.md evidence section for this step:

1. What did Step 9 (bug hunt) find? How many findings did qbcheck (Step 10) validate as real?
2. For EACH validated bug, did Step 11 fix it? Cite the commit/file:line.
3. For each fix, did I check OTHER locations in the codebase that might have the SAME bug pattern? (answer: yes/no + list)
4. Did I re-run the failing tests after each fix? Did they go green?
5. Did I add a regression test for each bug? (if not, why not?)
6. Is there any TRD/acceptance row that I cannot tick off with concrete evidence right now?

If ANY answer is unsatisfactory → go back to Step 11, do not proceed to 11.5.1.

### 11.5.∞ Loop-until-green contract

**If 11.5.1 (tests) or 11.5.2 (formatting) fails, this is NOT a reason to stop or defer. You MUST:**

1. Return to Step 11 (Fix Issues).
2. Fix the failing tests / formatter errors.
3. Re-run 11.5.0, 11.5.1, 11.5.2 from the top.
4. Repeat until all three pass. **There is no iteration cap.**

> **Never artificially stop this loop.** "Some tests were already failing on develop" is not a reason to proceed — verify against the Step 4.1 baseline. Only pre-existing baseline failures may remain; any NEW failure from your diff must be fixed before 11.5 passes.

### 11.5.1 Fresh Test Run

For EACH repo in `<AFFECTED_REPOS>`:

```bash
cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v 2>&1
echo "EXIT CODE: $?"
```

**Capture the FULL output.** Do NOT truncate with `| tail`. Read every line.

**Gate check:**
- Exit code MUST be 0
- No test failures, no errors
- Compare test count against the Step 4.1 baseline — new tests should have been added (TDD enforcement)
- If ANY pre-existing failures were noted in Step 4.1, verify they are still the ONLY failures (your changes didn't add new ones)

**If tests fail:** Do NOT proceed to Step 12. Go back to Step 11 and fix the failures first. Then re-run Step 11.5.

### 11.5.2 Fresh Formatting Check

```bash
cd <WORKTREE_PATH>/<repo-name> && black --check {{CODEBASE_PATH_PREFIX}}/ && isort --check {{CODEBASE_PATH_PREFIX}}/ && flake8 {{CODEBASE_PATH_PREFIX}}/
echo "EXIT CODE: $?"
```

**If formatting fails:** Fix it, re-run, confirm clean.

### 11.5.3 Phase 2 Findings Closure Audit

Read `<WORKTREE_PATH>/phase2-findings.md` and grep for unhandled MUST FIX rows:

```bash
grep -n "^- \[ \]" <WORKTREE_PATH>/phase2-findings.md | head -50
```

**Gate check:**
- Zero unchecked `- [ ]` rows under `## MUST FIX`. If any remain → return to Step 11.
- Zero `## MUST FIX` rows silently deleted vs the version Step 8.8 wrote. Verify with:
  ```bash
  cd <WORKTREE_PATH> && git log -p phase2-findings.md | head -200
  ```
  Every removed row must be reflected by a paired `## Rejected (with rationale)` row OR a `[x]` checked row with commit reference.

### 11.5.4 Evidence Record

Record the verification evidence in the completion report:

```
Step 11.5 Verification:     [PASS/FAIL]
  Tests:     <X> passed, <Y> failed | Exit code: <N>
  Baseline:  <B> passed (from Step 4.1) | New tests added: <X - B>
  Formatting: black [PASS/FAIL] | isort [PASS/FAIL] | flake8 [PASS/FAIL]
  Findings closure: <M> MUST FIX ticked | <R> rejected with rationale | <U> unhandled
                    (gate fails if U > 0)
```

**Phase 3 (E2E testing) CANNOT start without a PASSING Step 11.5.** This is non-negotiable.

---

## Step 11.6: Quick End-to-End Smoke (`/qe2etest`)

**Goal:** Run a fast end-to-end smoke against the current change before deferring to the full Phase 3 `/qe2etest` run. Catches "tests pass but the feature is dead" failures (wrong route registered, missing migration applied locally, JSON contract drift) without booting the full Playwright matrix.

**This is per-ticket and per-worker** — runs inside the worktree. Cheap; ~2-5 min. Output is recorded but Phase 3 still runs the full `/qe2etest` audit independently (with the full scenario matrix + UI delegation to `/qmanualt`).

```
Use the Skill tool:
  skill: "qe2etest"
  args: <TICKET_ID> — branches: <list branch names per repo>
```

**Exhaustiveness mandate (use this prompt language when invoking /qe2etest):**

> Test ALL possible scenarios for this change. For each changed code path, decide which trigger surfaces it touches — DB, API, UI, worker, cron, or any combination — and exercise every one of them. Do not stop at the happy path. Cover: happy paths, edge cases, boundary conditions, error paths, adversarial inputs, authz boundaries, regression on adjacent flows, state transitions, persistence / round-trip, and idempotency. If a scenario needs test data that doesn't exist locally, **seed it** (write a `.sh` script under `<WORKTREE>/seed-*.sh` and run it) before running the scenario. If you find a bug while testing, **fix it in place**, rebuild/restart as needed, re-run the affected scenario, and only then continue. Do NOT collect a "to fix later" list. The matrix is complete when every changed surface has been exercised AND every bug found has been fixed AND every scenario re-verifies green.

Step 11.6 is the *smoke* pass — the scope is the per-ticket diff, not cross-ticket integration. Phase 3 (Step 14) covers the full cross-ticket matrix. But within the per-ticket diff, the exhaustiveness mandate applies: don't ship a ticket with happy-path-only coverage.

**Gate check:**
- If `/qe2etest` reports any failure (HTTP non-2xx on the happy path, DB row missing after a write, console error in the affected page) → return to Step 11. Phase 3 will catch the same issues but more expensively.
- If `/qe2etest` reports BLOCKED (local stack won't boot) → record the reason in `phase2-progress.md` and proceed; Phase 3's `/qe2etest` will retry with full setup.

**DEV_MODE auth fallback (mandatory before reporting BLOCKED):** If `/qe2etest` fails specifically because the local stack was started with `DEV_MODE=false` and the test cannot authenticate (the external auth provider login required, 401/403 on every protected route, no usable session cookie, "Caller does not have access to this organization", etc.), DO NOT mark BLOCKED yet. Instead:

1. Stop your running service(s).
2. Relaunch them with `DEV_MODE=true` exported in the environment so the auth bypass kicks in. Reference `feedback_devmode_auth_layers.md` — {{COMPANY_SLUG_UPPER}} has 3 auth layers (FastAPI, cookies, admin role) and DEV_MODE bypasses all three.
3. Re-run `/qe2etest` against the DEV_MODE=true stack.
4. In `phase2-progress.md` Step 11.6 evidence row, record exactly: `relaunched with DEV_MODE=true after DEV_MODE=false failed at <auth surface>` so reviewers can see the env was downgraded for testability only.
5. Phase 3 (`/qe2etest`) is allowed to use the same DEV_MODE=true stack as long as the change under test does not itself touch the auth path.

Only mark `/qe2etest` BLOCKED if it still fails under DEV_MODE=true (i.e. the failure is unrelated to authentication).

**HARD CONSTRAINT — env-var only, no code changes (do not violate this).** The DEV_MODE fallback is purely an environment flip for the local process. You MUST NOT:

- Modify `oauth_provider_auth.py`, any middleware, any router, or any auth/permission code on the feature branch to "make DEV_MODE work."
- Commit any new `if DEV_MODE: return / bypass / skip` code on the feature branch.
- Edit `.env`, `serve.py`, or any startup script to wire new bypass logic.

If the existing codebase **does not** honour `DEV_MODE=true` on the auth surface you hit (e.g. Dash routes lacked the bypass, or only FastAPI side honours it), that is a **separate codebase gap** — it is NOT part of this ticket. Do this:

1. Mark Step 11.6 status `BLOCKED [dev_mode_gap: <auth surface>]` in `phase2-progress.md`.
2. Note the gap in the completion report and (optionally) suggest a follow-up ticket.
3. Proceed to Phase 3 only if `/qe2etest` can satisfy evidence via API curl + DB reads + Chrome MCP (via its `/qmanualt` delegation) without that auth surface.
4. Never extend the feature branch with auth-bypass code — every prior occurrence of "temporary DEV_MODE bypass committed by accident" in this monorepo became a real bug (`feedback_devmode_badge_deadlock.md`: "temporary, revert before commit").

If you have already committed an auth-bypass change as part of debugging, **revert it before Step 12 (Create PR)**. The PR diff must contain only the changes the ticket calls for.

Record:
```
Step 11.6 qe2etest:         [PASS/FAIL/BLOCKED]
  Scenarios run:    <list>
  Bugs found:       <count>  (every bug → Step 11 fix loop)
```

---

## Step 11.7: Memory Capture (`/qmemory`)

**Goal:** Persist learnings from this ticket so they apply to future tickets. The pipeline already mentions `/qmemory` opportunistically (Step 11.0, Step 14); this step makes it **mandatory** before Phase 3.

The historical failure: workers fix interesting bugs but never write the lesson, then the same class of bug recurs in the next epic. This step closes that gap.

**Trigger evaluation** — write a memory file IF any of these are true for this ticket:

- A bug was fixed in Step 11 that fits a pattern reusable across files/repos (cache invalidation, cross-origin auth, ORM session reuse, enum casing across services, Decimal-vs-float, etc.)
- The implementation revealed a non-obvious convention (e.g., "this repo's API uses hyphenated paths, not slashes")
- A subagent skipped or mis-applied a step in a way that should be hooked against in the future
- A migration / DB-write workflow needed a non-default knob (DEV_MODE patch, .env override, sibling-repo PYTHONPATH)
- The fix loop iterated 3+ times — that's a signal the root cause was non-obvious and worth recording

If ANY trigger fires:

```
Use the Skill tool:
  skill: "qmemory"
  args: <one-line description of the lesson>
```

Then verify the memory was written:

```bash
ls -la {{USER_HOME}}/.claude/projects/-Users-{{LOCAL_DB_USER}}-work-{{GH_ORG}}-{{COMPANY_SLUG}}-codebase/memory/ | head -20
```

The new file should be present with today's date. Reference it from `phase2-progress.md`:

```
Step 11.7 Memory Capture:   [DONE/SKIPPED]
  New memory files:  <list relative paths>
  OR
  Skipped because:   <one-line reason — e.g., "trivial typo fix, no reusable pattern">
```

**SKIPPED is allowed only with explicit reasoning.** The default is to capture.

---

---

## ⛔ PHASE 4: DELIVER (Orchestrator Only — runs ONCE across all tickets)

**Phase 4 starts ONLY after Phase 3 (E2E testing) passes.**

Phase 4 creates pull requests, runs final automated review ON the PRs, and validates the entire pipeline completed. PRs are created here — after all testing — so they capture the final, tested state of the code.

---

## Step 12: Create PR (qpr)

**Goal:** Stage, commit, push, and create a pull request for each affected repo.

### 12.1 Pre-flight Checks

For each repo in `<AFFECTED_REPOS>`:

```bash
cd <WORKTREE_PATH>/<repo-name> && git status
cd <WORKTREE_PATH>/<repo-name> && git branch --show-current
```

- Confirm current branch is `<BRANCH_NAME>` (NOT `develop` or `main`). If on develop or main, **STOP and warn the user**.

### 12.2 Stage Changes

```bash
cd <WORKTREE_PATH>/<repo-name> && git add -A
```

Verify what will be committed:
```bash
cd <WORKTREE_PATH>/<repo-name> && git diff --cached --stat
```

- Check that no sensitive files are staged (`.env`, credentials, secrets). If found, unstage them and warn.

### 12.3 Commit

1. Determine the commit prefix from the Jira issue type:

   | Issue Type | Prefix |
   |-----------|--------|
   | Bug | `fix:` |
   | Story / Task | `feat:` |
   | Subtask | `feat:` or `fix:` based on content |
   | Improvement | `refactor:` |

2. Draft commit message:
   - First line: `<prefix> <TICKET_ID> <concise summary>` (under 72 chars)
   - Body: explain the **why**, not just the **what**
   - Do **NOT** include `Co-Authored-By` lines

3. Commit using a HEREDOC:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && git commit -m "$(cat <<'EOF'
   <prefix> <TICKET_ID> <concise summary>

   <body explaining why>
   EOF
   )"
   ```

### 12.4 Push

```bash
cd <WORKTREE_PATH>/<repo-name> && git push -u origin <BRANCH_NAME>
```

### 12.5 Create Pull Request

1. Gather context for PR body:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && git log develop..HEAD --oneline
   cd <WORKTREE_PATH>/<repo-name> && git diff develop...HEAD --stat
   ```

2. Create the PR:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && gh pr create --title "<TICKET_ID> <concise summary>" --body "$(cat <<'EOF'
   ## Summary
   - <bullet point 1: what changed and why>
   - <bullet point 2: key implementation details>
   - <bullet point 3: if needed>

   ## Jira
   <TICKET_ID>

   ## Test plan
   - [ ] Unit tests pass (`pytest tests/ -v`)
   - [ ] Formatting passes (`black`, `isort`, `flake8`)
   - [ ] <specific test scenarios from acceptance criteria>
   EOF
   )" --base develop
   ```

3. Capture and store the PR URL for each repo.

### 12.6 Report

| Repo | Branch | PR URL |
|------|--------|--------|
| {{PRIMARY_REPO_NAME}} | `<BRANCH_NAME>` | https://github.com/... |
| {{PRIMARY_REPO_NAME}} | `<BRANCH_NAME>` | https://github.com/... |

---

## Step 12.0: Final Test Pass Before PR Creation (HARD GATE)

**Goal:** Re-run the full unit test suite for every affected repo immediately before `gh pr create`. Step 11.5 ran tests at the end of Phase 2, but Phase 3 (Step 14, qe2etest) may have applied fixes; without re-verifying, you can ship a PR whose unit tests broke during E2E remediation.

**This step is enforced by a `PreToolUse` hook** (`require-pre-pr-test-pass.sh`). The hook intercepts every `gh pr create` and blocks it unless a fresh `phase4-tests-passed.<repo>.flag` exists for each affected repo. You can't bypass it by accident — only by setting `QSHIP_SKIP_PRE_PR_TEST_GATE=1`, which is for emergency hand-PRs and leaves an audit trail.

### 12.0.1 Run the full suite per repo

For EACH repo in `<AFFECTED_REPOS>`:

```bash
cd <WORKTREE_PATH>/<repo-name>
# Use the repo's pinned interpreter, not system python.
export PATH="{{USER_HOME}}/.pyenv/shims:$PATH"
pytest tests/ -v 2>&1 | tee "{{STATE_ROOT}}/worktrees/<TICKET_ID>/phase4-pytest-<repo-name>.log"
EXIT=${PIPESTATUS[0]}
echo "exit=$EXIT"
```

Capture the FULL output. No `| tail`, no truncation — the fix loop in 12.0.2 needs the failure context.

### 12.0.2 Fix loop on failure

If `EXIT != 0` for any repo:

1. **Categorize each failure** (test-by-test): regression introduced by Phase 3 fix, flaky test, environment difference, missing migration, broken import, assertion drift.
2. **Apply the smallest fix per failure** using systematic-debugging from §11.2 (root cause → smallest fix → verify). Forbidden "fixes" are the same as Step 12.6: no `pytest.skip`, no `# noqa`, no SUT-stubbing, no `assert True`. If a test reveals a real bug introduced during Phase 3, the fix is a code fix — not a test deletion.
3. **Re-run the FULL suite** for that repo (not just the failing test):
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && pytest tests/ -v
   ```
4. **Loop** until exit code is 0. `MAX_FINAL_TEST_FIX_ITERS=10` — beyond that, halt and surface to user (likely a flaky-test or environment issue that needs human judgment).

### 12.0.3 Drop the flag file per green repo

Once a repo's full suite is green, write its flag:

```bash
touch "{{STATE_ROOT}}/worktrees/<TICKET_ID>/phase4-tests-passed.<repo-name>.flag"
```

The hook checks:
- File exists: ✅
- File mtime is within `QSHIP_TEST_FLAG_FRESHNESS_MIN` (default 60 min): ✅
- File mtime is newer than the most recent commit on the branch: ✅ (otherwise commits landed after tests ran → re-run required)

### 12.0.4 Recording

```
Step 12.0 Final Test Pass:
  <repo-1>: <X> passed | <Y> failed (fixed in <K> iterations) | flag: phase4-tests-passed.<repo-1>.flag
  <repo-2>: ...
```

**Hook behaviour:**
- All flags present, fresh, ahead of HEAD → `gh pr create` proceeds.
- Any flag missing / stale / behind HEAD → `gh pr create` blocked with a message naming which repo failed which check.
- No qship ticket detected in the `gh pr create` command (hand PR with no ticket id) → hook lets through.
- `QSHIP_SKIP_PRE_PR_TEST_GATE=1` set → escape hatch, hook lets through.

The hook is wired in `~/.claude/settings.json` under `PreToolUse → matcher: "Bash"`. It calls `~/.claude/skills/qship/hooks/require-pre-pr-test-pass.sh`. If the hook is unregistered, this step is advisory; verify with `jq '.hooks.PreToolUse[].hooks[].command' ~/.claude/settings.json | grep require-pre-pr-test-pass`.

---

## Step 12.5: Watch CI (block until PR checks complete)

**Goal:** Don't claim Phase 4 done until each created PR's CI has actually finished. Step 12 creates PRs; CI fires asynchronously; without watching it, qship can yield with green Phase 4 evidence while CI is still pending and silently fails seconds later.

For EACH PR URL captured in §12.5 of Step 12, get the PR number and watch its checks:

```bash
PR_URL="<from Step 12>"
PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/pull/([0-9]+).*|\1|')
REPO=$(echo "$PR_URL" | sed -E 's|.*github.com/([^/]+/[^/]+)/pull.*|\1|')

# Wait for all checks to complete (succeeds, fails, or times out at 30 min)
gh pr checks "$PR_NUM" --repo "$REPO" --watch --interval 30 \
  > "{{STATE_ROOT}}/worktrees/<TICKET_ID>/ci-watch-<repo-name>.log" 2>&1
WATCH_EXIT=$?
```

`gh pr checks --watch` returns 0 only when ALL checks pass; non-zero on any failure. Capture the exit code per repo.

**Outcomes:**

| `gh pr checks --watch` exit | Action |
|---|---|
| 0 (all green) | Record `Step 12.5 [PASS] all CI checks passed` and proceed to Step 13. |
| Non-zero (one or more failed) | Proceed to Step 12.6 — auto-fix CI failures. |
| Timeout / network failure | Re-run the watch. If it times out repeatedly, record `Step 12.5 [TIMEOUT]`, capture the in-progress check IDs, and move to Step 12.6 with whichever checks have failed so far. Don't yield to user. |

Record:
```
Step 12.5 Watch CI:
  <repo>: <PASS / FAIL / TIMEOUT>  (exit=<N>, duration=<min>m, log: ci-watch-<repo>.log)
```

---

## Step 12.6: Auto-Fix CI Failures

**Goal:** When Step 12.5 reports failures, fetch the failing job logs, dispatch a focused fix subagent against the worktree, push the fix, return to Step 12.5. Loop until green or `MAX_CI_FIX_ITERS` exhausted.

This step exists because CI catches what local Step 11.5 cannot:
- Different Python version (CI runs the project Python; local sometimes drifts)
- Missing migration applied on a fresh DB
- Test data that exists locally but isn't seeded in CI
- Lint rules with stricter CI config (e.g., `--strict`)
- Cross-repo integration tests that only run in CI

### 12.6.1 Fetch the failing logs

```bash
PR_NUM=<from Step 12.5>
REPO=<from Step 12.5>

# List failing checks
gh pr checks "$PR_NUM" --repo "$REPO" \
  | awk '$2=="fail"' \
  > "{{STATE_ROOT}}/worktrees/<TICKET_ID>/ci-failed-<repo-name>.txt"

# For each failed check, fetch the run log
gh run list --repo "$REPO" --branch "<BRANCH_NAME>" --limit 5 --json databaseId,name,conclusion \
  | jq -r '.[] | select(.conclusion=="failure") | .databaseId' \
  | while read -r RUN_ID; do
      gh run view "$RUN_ID" --repo "$REPO" --log-failed \
        > "{{STATE_ROOT}}/worktrees/<TICKET_ID>/ci-log-${RUN_ID}.log"
    done
```

`--log-failed` is the key flag — it fetches only failing-step logs, not the entire CI run. Avoids drowning the fix subagent in passing-step noise.

### 12.6.2 Dispatch focused fix subagent

```
Task(
  subagent_type: "general-purpose",
  mode: "bypassPermissions",
  description: "Fix CI failures for <TICKET_ID> PR #<PR_NUM>",
  prompt: |
    Read ~/.claude/skills/qship/references/autonomy-contract.md before starting.

    Your job: fix the CI failures captured in
      {{STATE_ROOT}}/worktrees/<TICKET_ID>/ci-log-*.log

    Worktree:    {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>
    Branch:      <BRANCH_NAME>
    PR:          <PR_URL>

    Steps:
    1. Read every ci-log-*.log file. Identify each distinct failure:
       - Test failure (pytest output)
       - Lint failure (black/isort/flake8/autoflake)
       - Pre-commit failure (detect-secrets, trailing-whitespace)
       - Migration failure (alembic upgrade)
       - Type/import failure (mypy, ImportError)
    2. Apply the fix using the systematic-debugging discipline from
       ~/.claude/skills/qship/pipeline-steps.md §11.2 (root cause → smallest fix).
       DO NOT skip tests. DO NOT add `# noqa` to mute lints. DO NOT pin the
       failing dep without root-causing.
    3. Verify locally:
         cd <worktree>/<repo-name>
         pre-commit run --all-files
         pytest tests/ -v
       Both must pass.
    4. Commit and push:
         git add -A
         git commit -m "fix(ci): <one-line summary> for <TICKET_ID>"
         git push origin <BRANCH_NAME>
    5. Return a 5-line summary: failure category, root cause, fix, files changed, commit SHA.

    Forbidden "fixes": pytest.skip, @pytest.mark.skip, assert True, deleting
    the failing test, # noqa, # type: ignore, stubbing the SUT to a hardcoded
    return value. The orchestrator's qbcheck pass will reject any of these.
)
```

### 12.6.3 Loop back to Step 12.5

After the fix subagent pushes:

```bash
# Wait for CI to start on the new commit, then watch:
sleep 30
# Re-enter Step 12.5
```

**Loop guard:** `MAX_CI_FIX_ITERS=5`. After 5 unsuccessful iterations on the same PR, stop and escalate to user with:
- Final `gh pr checks` output
- Last 200 lines of each failing log
- Summary of what each iteration tried
- Hypothesis for why the loop isn't converging (e.g., flaky test, infrastructure issue, missing secret)

### 12.6.4 Pre-commit specifics

If the failure is a pre-commit hook (most commonly `detect-secrets` flagging a new entropy match, or `trailing-whitespace` from a paste), the fix subagent should:

- For `detect-secrets`: re-baseline with `detect-secrets scan --baseline .secrets.baseline` and audit the new findings (`detect-secrets audit .secrets.baseline`). Mark as is_secret: false ONLY for confirmed false positives.
- For formatting hooks (black, isort, autoflake, trailing-whitespace): the hooks auto-fix on local re-run. Just `pre-commit run --all-files`, commit the diff.
- For flake8: real lint violation — fix the code, never `# noqa`.

### 12.6.5 Recording

```
Step 12.6 Auto-Fix CI:
  Iteration 1: <N> failures (<categories>) → fixed in <commit-sha> → CI pass=<bool>
  Iteration 2: ...
  Final: PASS after <K> iterations  OR  ESCALATED after MAX_CI_FIX_ITERS
```

When PASS, return to Step 12.5 confirms green, then proceed to Step 13. When ESCALATED, halt and surface to user — do NOT mark Phase 4 complete.

---

## Step 13: Final Review

**Goal:** Run an automated code review on each created PR to catch anything missed.

**Invoke the code-review skill:**

```
Use the Skill tool:
  skill: "code-review:code-review"
  args: "<PR_URL>"
```

Run this for EACH PR created in Step 12.

The code-review skill will:
1. Check PR eligibility (not draft, not already reviewed)
2. Read CLAUDE.md files relevant to changed directories
3. Summarize the change
4. Launch 5 parallel review agents (CLAUDE.md compliance, bug scan, git history, past PR comments, code comments)
5. Score each finding (0-100 confidence)
6. Filter to high-confidence issues (score >= 80)
7. Post a review comment on the PR

### 13.1 Handle Review Findings

If the code-review skill finds issues with score >= 80:

1. Read the review comment posted on the PR
2. For each flagged issue:
   - Verify it is a real issue (not a false positive)
   - If real: fix it, re-run tests, amend the commit, force-push
   - If false positive: note it but take no action
3. If fixes were applied:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && git add -A && git commit -m "fix: address code review findings" && git push
   ```

### 13.2 Pipeline Complete

Report the final status to the user:

```
Pipeline complete for <TICKET_ID>.

| Step | Status |
|------|--------|
| Jira Fetch | done |
| Repo Detection | <AFFECTED_REPOS> |
| Pull Latest | done |
| Create Branch | <BRANCH_NAME> |
| Baseline Verify | <N> tests passed on clean branch |
| Write Plan | docs/plans/<plan-file>.md |
| Plan Review | passed |
| Implement (TDD) | done — <N> TDD cycles, <M> batch commits |
| Directory Check | <N files moved / no issues> |
| Clean Defensive Code | <N removals / no issues> |
| Simplify | done |
| Code Review | <N issues found> (incl. spec compliance) |
| Bug Hunt | <N raw findings> |
| Bug Validation | <N validated, M rejected as false positives> |
| Fix Issues | <N bugs fixed> (systematic debugging) |
| Verification Gate | PASS — <X> tests passed, formatting clean |
| E2E Testing | <X/Y tests passed> |
| Create PR | <PR URLs> |
| Final Review | <review result> |
| Pipeline Check | qshipcheck PASSED |
```

### 13.3 Bug Summary

Include the full bug validation summary from `<BUG_VALIDATION_SUMMARY>`:

```
Bug Hunt & Validation Summary
==============================

qbug raw findings: <N total>
qbcheck validated: <V real bugs>, <O overstated>, <F false positives>, <T overthinking>
Bugs fixed: <X>

| # | Finding | qbug Severity | qbcheck Verdict | Action Taken |
|---|---------|---------------|-----------------|--------------|
| 1 | [description] | Critical | REAL BUG | Fixed |
| 2 | [description] | High | FALSE POSITIVE | Rejected |
| ... | ... | ... | ... | ... |
```

If no bugs were found by qbug, report:
```
Bug Hunt & Validation Summary: No issues found by qbug. Clean code!
```

---

---

## ⛔ PHASE 3: ACCEPTANCE (Delegated to Sub-Agent, Audited by Orchestrator)

**Phase 3 starts ONLY after ALL tickets have completed Phase 2 (Step 11.5 DONE for every ticket).**

Phase 3 is dynamic validation — running actual servers, hitting real endpoints, checking database state. This is fundamentally different from Phase 2's static code analysis and catches integration issues that per-ticket review cannot.

**Architecture:** The orchestrator NEVER runs tests itself. It dispatches an Opus sub-agent to execute tests, then **audits the results for completeness**. If gaps exist, the orchestrator re-dispatches with specific instructions to test the missing scenarios. This loop continues until every feature is tested.

**After Phase 3 passes the coverage audit, proceed to Phase 4 (Deliver) for PR creation and final review.**

---

## Step 13.9: Compute Pipeline Context (mandatory pre-Phase-3)

**Goal:** Classify the final diff so the E2E sub-agent AND the Stop/PreToolUse hooks know whether API evidence, UI evidence, or both are required.

**Run ONCE before Step 14, after all Phase 2 fixes are committed:**

```bash
bash {{USER_HOME}}/.claude/skills/qship/hooks/qship-compute-context.sh <TICKET_ID>
```

This writes `{{STATE_ROOT}}/worktrees/<TICKET>/pipeline-context.json` with:

- `api_changed` (bool) — any `{{CODEBASE_PATH_PREFIX}}/**/api/**/*.py` file changed → API E2E required
- `ui_changed` (bool) — any UI file changed (`*.tsx`, `*.jsx`, `*/ui/**`, `*/components/react/**`, `*/dash_pages/**`) → UI E2E required
- `ui_consumer_changed` (bool) — a changed endpoint is referenced from UI source → UI regression E2E required
- `changed_endpoints`, `api_files_changed`, `ui_files_changed`, `ui_consumer_refs` — diagnostic arrays

**Step 14 (E2E) reads these booleans and:**
- If `api_changed=true` → must run API E2E (curl/httpx per changed endpoint) and write the `## API Evidence` section of phase3-evidence.md
- If `ui_changed=true OR ui_consumer_changed=true` → must run UI E2E via Playwright MCP with `--reporter=json` and `trace: 'on'`, then write `## UI Evidence` referencing the results.json + trace.zip paths
- If both false → acceptable to write a short rationale-only `phase3-evidence.md`

**The Stop hook and PreToolUse gate enforce this contract. Skipping qship-compute-context.sh → all terminations and PR pushes will be blocked with "pipeline-context.json missing".**

---

## Step 14: E2E Manual Testing

**Goal:** Run end-to-end acceptance testing against running services to validate the full feature works.

**This step is delegated to an Opus sub-agent that runs `/qe2etest`, audited by the orchestrator for coverage completeness. `/qe2etest` traces the diff, drives API / worker / cron triggers live against the running stack, verifies DB state, and delegates any UI surface to `/qmanualt` (Playwright + Claude in Chrome).**

### 14.0a Skeptical Critic-Orchestrator Contract (orchestrator side)

The orchestrator runs an **actor-critic loop** around the E2E sub-agent. This formalises the loop already encoded in `/qmanualt`'s PERSONA section (which `/qe2etest` inherits when it delegates UI work) and adds the orchestrator-side enforcement.

<orchestrator_role>
You are a **skeptical Senior QA Engineer + Senior Software Engineer**. The E2E sub-agent is the actor; you are the critic. Your job is NOT to accept the actor's report. Your job is to falsify it.

For every "PASS" the actor returns, you must produce at least one falsification attempt:
- Cross-check the actor's evidence against the actual code diff (does the diff include code paths not exercised?).
- Verify the actor ran the FULL <scenario_taxonomy> from qmanualt (happy + boundary + error + adversarial + authz + regression on adjacent + state transitions + persistence + idempotency + cross-repo), not just the happy path.
- Walk the diff file-by-file. For every changed symbol, ask: "Where in the actor's matrix is this exercised live?"
- For every fix the actor applied during its run, verify the actor re-ran the FULL matrix afterward (not just the failing scenario). If only the failing scenario was re-run, redispatch.

You may NOT mark Step 14 done while any of the following is true:
- A "PASS" lacks live evidence (curl response body, psql row, screenshot at moment of assertion).
- A scenario is "BLOCKED" without a concrete infra reproducer.
- Any fix was applied without a subsequent full-matrix re-run.
- Any anti-pattern phrase appears in the report ("looks fine", "probably works", "should work", "skipped for time").
- Cross-repo contract changes were exercised in only one repo's surface.
</orchestrator_role>

<actor_critic_dispatch_loop>
```
iteration = 0
findings = []

REPEAT:
  iteration += 1

  # ACTOR: dispatch /qe2etest sub-agent
  - Pass the ticket(s), diff, AC list, and prior findings (if any).
  - Sub-agent runs /qe2etest (diff tracing → live API/worker/cron drive → DB verify → UI delegated to /qmanualt).
  - Sub-agent runs the full PERSONA & ACTIVE CRITIC-ORCHESTRATOR LOOP from qmanualt for the UI portion.
  - Sub-agent returns: scenario matrix with PASS/FAIL + evidence + bug log + fixes applied.

  # CRITIC: orchestrator audits (this is the gate)
  Audit checklist (every box must be ticked or it's a gap):
  □ Every AC row has live evidence (not Jest-only, not source-proof).
  □ Every changed file in the diff maps to ≥1 live scenario.
  □ Every code branch added in the diff (new if/elif, new exception, new enum value) has a triggering scenario.
  □ Every new endpoint hit with: valid input, invalid input, wrong-tenant input, missing-auth input.
  □ Every new modal: opened, filled, SUBMITTED (not just cancelled), DB row verified.
  □ Every state transition in the diff exercised.
  □ Every fix applied during the run was followed by a FULL matrix re-run (verify by checking the report's re-run log).
  □ Cross-repo contract changes exercised in BOTH repos' live surfaces.
  □ Console + {{PRIMARY_REPO_NAME}}.log + {{PRIMARY_REPO_NAME}}.log + {{COMPANY_SLUG}}-worker.log grep'd for ERROR/500/Traceback per scenario.
  □ No banned phrases in the report ("looks fine", "probably works", "skipped for time", "out of scope").
  □ Every BLOCKED row has a concrete infra reproducer (not a time/effort excuse).

  IF all boxes ticked AND zero new critic findings → DONE.
  ELSE → compose targeted gap prompt and REDISPATCH.

  # Loop guard
  Hard cap: 6 iterations (was 3 — raised because in practice 3 is too few when fixes regress adjacent scenarios).
  IF iteration ≥ 6 AND gaps remain → escalate to user with: matrix snapshot, remaining findings, reproducers. Do NOT silently accept.
```
</actor_critic_dispatch_loop>

<post_fix_full_matrix_rerun>
**Most-violated rule. Enforce explicitly.**

Every time the actor reports "fixed bug X", the orchestrator's next critic question is:
> "Show me the post-fix re-run log for the FULL matrix, not just scenario X."

If the actor only re-ran the failing scenario, the redispatch prompt MUST say:
```
You re-ran only scenario X after fixing bug X. That is insufficient.
Re-run the FULL <scenario_taxonomy> matrix for the affected feature AND every adjacent
feature in the Impact Path. Report each cell's PASS/FAIL with timestamps proving the
re-run happened AFTER the fix commit. Regressions found during re-run become the new
lead bug — loop back to actor-critic on them.
```

Rationale: a fix in one place commonly regresses an adjacent scenario (cache invalidation, ORM session reuse, callback wiring, FK cascade, stale React bundle). Spot-checks ship regressions.
</post_fix_full_matrix_rerun>



The orchestrator dispatches the sub-agent with the `/qe2etest` skill invocation. The sub-agent reads and follows the full qe2etest skill: audit the diff, trace every changed code path to its production trigger (HTTP / worker / cron / scheduled job), run `/qspinuplocal`, drive the triggers live, verify DB state, and delegate any UI surface to `/qmanualt` (which handles setup, DEV_MODE patches, health checks, full UI test matrix, screenshots, cleanup). The orchestrator monitors progress and audits the results.

### 14.0 Pre-Testing Memory Search

Before starting E2E testing, search memories for:
- DEV_MODE workarounds (badge deadlock, dotenv override, session check disable)
- Local testing gotchas (load_dotenv override=True, worker count, auth patches)
- Previous E2E test failures on similar features

**During E2E testing:** If you discover a new bug, fix it, and it represents a reusable lesson (e.g., "all React components need 204 handling", "cross-repo API URLs use hyphens not slashes"), write a memory file IMMEDIATELY before continuing to the next test.

### 14.1 Invoke qe2etest

Use the `Skill` tool to invoke the qe2etest skill:

```
Skill: qe2etest
Args: <EPIC_ID or TICKET_IDs> — <brief summary>. Branches: <list branch names per repo>
```

The qe2etest skill handles:
- Auditing the diff and tracing every changed code path forward to its production trigger (HTTP endpoint, worker queue, cron, scheduled job)
- Running `/qspinuplocal` to start the local stack (your services + worker) on the feature branches; creating integration branches when needed (multi-ticket epics)
- Driving API / worker / cron triggers live against the running stack
- Verifying DB state after every trigger (schema + row-level)
- **Delegating any UI surface to `/qmanualt`** (Playwright + Claude in Chrome) — qe2etest does NOT drive the UI itself; qmanualt owns setup, DEV_MODE patches, the full UI scenario matrix, screenshots, and cleanup
- Testing cross-ticket integration when multiple repos/branches are in scope
- Posting consolidated test results as a Jira comment

### 14.2 Fix-Then-Retest Loop (MANDATORY)

**Phase 3 is not just testing — it is a fix-and-verify cycle.** Every bug found MUST be fixed immediately and the affected area retested before moving on. Do NOT accumulate bugs into a list for later. Do NOT mark Phase 3 as done with known unfixed bugs.

**For EVERY bug found during E2E testing:**

1. **Stop testing.** Do not continue testing other areas while a bug is open.
2. **Fix the bug** in the relevant worktree. Apply the smallest possible fix.
3. **Rebuild if needed** (e.g., `npm run build` for React changes, restart servers for Python changes).
4. **Re-run the specific failing test** to confirm the fix works.
5. **Take a screenshot** of the fixed state (save to `uat/` directory with descriptive name).
6. **Re-run ALL previously passing tests** in the affected area to confirm no regressions.
7. **Log the bug + fix** in the test report:
   ```
   BUG FOUND: <description>
   ROOT CAUSE: <why it happened>
   FIX: <what was changed, which file:line>
   RETEST: <PASS/FAIL — with screenshot evidence>
   ```
8. **Only then** continue testing the next area.

**If a fix introduces a new failure:**
- Stop, fix the new failure first (same loop)
- This is recursive — no bug is left open at any point
- 3-fix limit: if the same bug resists 3 fix attempts, escalate to the user

**Anti-skip rules:**
- "I'll fix this later" → NO. Fix it now.
- "This is a known limitation" → If it's a code bug, fix it. If it's infrastructure (e.g., LLM endpoint down), document it clearly as INFRA BLOCKED with the specific error and what would need to change.
- "The test passed with a workaround" → The workaround IS the fix. Commit it.
- "It works when I test manually" → Screenshot evidence or it didn't happen.

### 14.3 Rebuild-Restart Protocol

After fixing any bug during E2E:

**Python changes:**
```bash
# Kill and restart the affected server
lsof -ti:<PORT> | xargs -r kill -9
sleep 2
# Restart with same DEV_MODE command as before
```

**React/JSX changes:**
```bash
# Rebuild webpack bundle
cd <worktree>/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react && npx webpack --mode production
# Restart {{PRIMARY_REPO_NAME}} server (bundle is served statically)
lsof -ti:8000 | xargs -r kill -9 && sleep 2 && <restart command>
```

**After restart, verify health before retesting:**
```bash
curl -s http://127.0.0.1:8001/health  # {{PRIMARY_REPO_NAME}}
curl -s http://127.0.0.1:8000/health  # {{PRIMARY_REPO_NAME}}
```

### 14.4 Screenshot Evidence Requirements

**Every test action MUST have a screenshot.** Save all screenshots to the UAT directory:
```
{{CODEBASE_ROOT}}/uat/<TICKET>-<NN>-<description>.png
```

Required screenshots (at minimum):
- Each page load (after data renders, not during "Updating...")
- Each modal opened (with data loaded)
- Each button click result (success notification, error notification, state change)
- Before AND after each fix (showing the bug, then showing it fixed)
- Console errors check (`browser_console_messages level="error"`)

### 14.5 Report

Include E2E results in the final completion report:

```
Step 14 E2E Testing:          [DONE] X/Y tests passed | Bugs found: N, Fixed: N | Screenshots: uat/
```

The report MUST include:
1. **AC Test Matrix** — every acceptance criterion mapped to test result (PASS/FAIL/PARTIAL)
2. **Bug Log** — every bug found, root cause, fix applied, retest result
3. **Screenshot Index** — numbered list of all screenshots with descriptions
4. **Console Errors** — any JS errors and whether they are from new code or pre-existing
5. **Server Log Errors** — any 500/404/timeout errors from any of your repos logs

Phase 3 CANNOT be marked DONE if:
- Any fixable bug was found but not fixed
- Any fix was applied but not retested
- Any retest failed after a fix
- Screenshots are missing for key test actions
- The coverage audit (Step 14.6) has not passed

### 14.6 Dispatch-Audit-Redispatch Loop (MANDATORY)

**The orchestrator NEVER runs Phase 3 tests itself.** It delegates to sub-agents and audits their results. The loop is:

```
REPEAT:
  1. DISPATCH: Launch Opus sub-agent with test scenarios
  2. WAIT: Sub-agent executes tests, fixes bugs, returns report
  3. AUDIT: Orchestrator compares test report against code diff
  4. If GAPS exist → REDISPATCH with gap-specific instructions
  5. If NO GAPS → Phase 3 DONE
```

#### Step 14.6.1: Dispatch E2E Sub-Agent with /qe2etest

Launch an Opus sub-agent (`model: "opus"`) that runs the `/qe2etest` skill. The sub-agent prompt MUST:

1. **Invoke the qe2etest skill** — the sub-agent reads and follows the full qe2etest command (diff tracing → triggers → live API/worker/cron drive → DB verification → UI delegated to `/qmanualt` for setup, patches, health checks, test matrix, deep CRUD testing, modal lifecycle, backend pipeline testing, screenshots)

2. **Include the ticket context** — ticket ID, summary, acceptance criteria, affected repos, branch names

3. **Include a test scenario list** derived from the code diff:
   - For each new API endpoint → API test scenario
   - For each new UI component → Playwright interaction scenario
   - For each new modal → open, fill, SUBMIT (not cancel), verify result
   - For each new background job → trigger + run worker + verify completion
   - For each new validation → error case scenario

4. **Include these CRITICAL RULES in the prompt:**
```
EXHAUSTIVENESS MANDATE — non-negotiable.

You need to /qe2etest ALL possible scenarios for this change. For each
changed code path, decide which trigger surfaces it touches — DB, API,
UI, worker, cron, or any combination — and exercise every one of them.
Do not stop at the happy path. Cover the full scenario taxonomy:

  - happy paths
  - edge cases + boundary conditions (empty, max, off-by-one, negative,
    zero, large strings, special chars, Decimal precision)
  - error paths (every 4xx/5xx the new code can produce — TRIGGER each)
  - adversarial inputs (malformed JSON, SQL-like strings, unicode, XSS)
  - authz boundaries (the change must not widen who can access what)
  - regression on adjacent flows touched by the diff
  - state transitions (every status / lifecycle hop the change introduces)
  - persistence / round-trip (write → re-read → verify equality)
  - idempotency (same request twice → same outcome, no dup rows)
  - cross-repo integration when the diff touches more than one repo

CRITICAL RULES — READ AND FOLLOW:
- Do NOT just open modals and cancel. EXECUTE every operation.
- After every mutation, VERIFY via API that the DB state changed correctly.
- Take screenshots BEFORE and AFTER every action.
- If anything fails, FIX IT in place (the worktree), rebuild, restart,
  retest. Do NOT collect a "to fix later" list — fix-as-you-find.
- Do NOT stop until ALL scenarios pass AND every fix re-verifies green.
- Do NOT skip any scenario for "time constraints". You have unlimited time.
- If infrastructure is unavailable (e.g., LLM endpoint), test everything
  that CAN work without it and clearly document what was INFRA BLOCKED.
- Run the record processing worker if the feature involves background jobs.
- Seed any necessary test data (write .sh scripts for DB writes, save them
  to <WORKTREE>/seed-*.sh, run them, keep the script as a re-runnable
  artifact for the evidence file).
- Apply DEV_MODE patches per qmanualt instructions. REVERT during cleanup.
- Every new button must be CLICKED. Every new modal must be SUBMITTED.
  Every new endpoint must be CALLED. Every error path must be TRIGGERED.
- The matrix is complete only when: every changed surface exercised AND
  every bug found fixed AND every scenario re-verifies green.
```

5. **Include the UAT screenshot directory:** `{{CODEBASE_ROOT}}/uat/frames/`

#### Step 14.6.2: Audit Sub-Agent Results

After the sub-agent completes, the orchestrator MUST:

1. **Read the sub-agent's final report** — extract the test matrix (PASS/FAIL/SKIP for each scenario)

2. **Build the expected test coverage** from the code diff:
   ```bash
   cd <WORKTREE> && git diff <BASE_BRANCH>..HEAD --name-only
   ```
   For each changed file, determine what features it implements:
   - New API endpoint → must have API test (curl + status code + response body verification)
   - New UI component → must have Playwright test (navigate, interact, screenshot)
   - New modal → must be OPENED, FILLED, SUBMITTED, and VERIFIED (not just opened and cancelled)
   - New background job → must be TRIGGERED and WORKER RUN (or documented as INFRA BLOCKED)
   - New DB table → must have data written to it and read back during tests
   - New validation → must have error case tested (invalid input → correct error message)

3. **Compare expected vs actual coverage:**
   ```
   For each expected test:
     - If PASS → ✓
     - If FAIL → BUG (sub-agent should have fixed it)
     - If SKIP → GAP (must be retested unless INFRA BLOCKED with specific error)
     - If MISSING (not in report) → GAP
   ```

4. **Produce a gap analysis:**
   ```
   COVERAGE AUDIT — <TICKET_ID>
   ================================
   Expected scenarios: N
   Tested (PASS): X
   Tested (FAIL, fixed): Y
   Skipped: Z
   Missing: W

   GAPS:
   - [ ] <scenario description> — reason: <SKIP reason or MISSING>
   - [ ] <scenario description> — reason: <not executed, only opened modal>
   ```

#### Step 14.6.3: Redispatch for Gaps

If ANY gaps exist (skipped or missing scenarios):

1. **Compose a targeted prompt** for a NEW sub-agent that ONLY tests the gaps:
   ```
   You MUST test these N scenarios that were skipped/missing in the previous run.
   EXECUTE every action, VERIFY every result, take screenshots.
   Do NOT skip anything. Do NOT stop until ALL scenarios pass.

   Previous sub-agent skipped these because: <reasons>
   Your job is to find a way to test them anyway, or clearly document
   exactly what infrastructure is missing and what the test WOULD verify.

   SCENARIOS:
   1. <gap scenario with detailed steps>
   2. <gap scenario with detailed steps>
   ...
   ```

2. **Include the previous sub-agent's setup state** — servers may still be running, test data may exist, patches may be applied. The new sub-agent should verify the environment before testing.

3. **Wait for the new sub-agent to complete**, then re-audit.

4. **Maximum 6 redispatch iterations** (raised from 3 — see `<actor_critic_dispatch_loop>` in 14.0a; in practice 3 was too few when fixes regress adjacent scenarios and trigger the full-matrix re-run mandate). If gaps remain after 6 rounds:
   - Mark remaining gaps as BLOCKED with detailed justification
   - Escalate to user: "These N scenarios could not be tested because: <reasons>"
   - The user decides whether to proceed or fix the blockers

#### Step 14.6.4: Coverage Audit Pass Criteria

Phase 3 passes the coverage audit when ALL of the following are true:

1. **Every new API endpoint** has been called with valid input AND invalid input, and response verified
2. **Every new UI component** has been interacted with via Playwright (not just rendered)
3. **Every new modal** has been opened, filled, SUBMITTED (not cancelled), and the result verified
4. **Every new background job** has been triggered AND the worker has processed it (or INFRA BLOCKED documented)
5. **Every merge/delete/update operation** has been EXECUTED and the DB state verified after
6. **Every error handling path** has been triggered (invalid input, whitespace, empty, etc.)
7. **Every new button** has been clicked and its effect verified
8. **Screenshot evidence exists** for every test action
9. **Console and server logs** checked for errors after each major action
10. **All bugs found during testing** have been fixed, committed, and the fix verified

Only when all 10 criteria are met does the orchestrator mark Phase 3 as DONE.
