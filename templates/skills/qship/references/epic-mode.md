# qship — Epic & multi-wave execution (reference)

Extracted from `SKILL.md` for progressive disclosure (Anthropic skill best
practice: keep the SKILL.md spine focused; move distinct execution paths to
references). The orchestrator loads this when `EPIC_MODE=true`, when running
dependency-stacked ticket batches, or when consolidating an epic's PRs.

---

## Dependency-Aware Branching

When running individual tickets (not via Epic Mode), tickets may still have dependencies on other tickets that have already been implemented and have existing branches or PRs. This is common when running additional waves of an in-progress epic, or when tickets reference blockers in their Jira descriptions.

**This section runs AFTER Step 1 (Jira Fetch) and BEFORE worktree creation.**

### D1. Parse Dependencies from Jira

For each ticket in `TICKETS`, extract blocker ticket IDs from:

1. **Description field**: Look for lines matching `Blocked by: <ID>` or `Blocked by: <ID>, <ID>, ...`
2. **Jira issue links**: Check for `is blocked by` link types in the issue metadata
3. **Parent epic context**: If the ticket has a parent epic, fetch sibling stories to understand the dependency chain

```
For each ticket T in TICKETS:
  T.blockers = []

  # Parse "Blocked by:" from description
  for each line in T.description matching /Blocked by:\s*(.+)/i:
    extract comma-separated ticket IDs → add to T.blockers

  # Also check Jira issue links
  for each link in T.issueLinks where link.type == "is blocked by":
    add link.inwardIssue.key to T.blockers
```

### D2. Resolve Blockers to Branches

For each blocker ticket ID, determine if it has an existing branch in the target repo:

```bash
# For each blocker ID, search for matching branches
git -C {{CODEBASE_ROOT}}/<repo-name> branch -a | grep -i "<BLOCKER_ID>"
```

**Resolution priority:**
1. **Local branch exists** → use it as BASE_BRANCH
2. **Remote branch exists** (origin/<branch>) → fetch and use it
3. **No branch found** → blocker may be in a different repo (cross-repo dep) or already merged to develop

**If the blocker is already merged to `develop`:**
```bash
# Check if blocker branch was merged
git -C {{CODEBASE_ROOT}}/<repo-name> log --oneline develop | grep -i "<BLOCKER_ID>"
```
If merged → branch from `develop` (no stacking needed).

### D3. Build Dependency Graph and Waves

Among the provided `TICKETS`, build a dependency graph:

```
For each ticket T:
  T.resolved_base = "develop"  # default
  T.pr_target = "develop"      # default

  for each blocker B in T.blockers:
    if B is in TICKETS (inter-batch dependency):
      # B will be implemented in this run — T must wait for B
      T.depends_on_in_batch.add(B)

    elif B has an existing branch in T's repo (same-repo):
      # B was already implemented — T stacks on B's branch
      T.resolved_base = <B's branch name>
      T.pr_target = <B's branch name>

    elif B is in a different repo (cross-repo):
      # Cross-repo dep — T still branches from develop in its own repo
      # (no branch stacking across repos)
      pass
```

**Group tickets into waves** (same logic as Epic Mode §E2):
- **Wave 1**: Tickets with no unresolved in-batch blockers
- **Wave 2**: Tickets whose in-batch blockers are all in Wave 1
- **Wave N**: Tickets whose in-batch blockers are all in Waves 1..N-1

### D4. Display Dependency Plan

Before creating worktrees, display the resolved plan:

```
Dependency Resolution
=====================

| Ticket  | Repo         | Blocker(s)     | Base Branch                    | PR Target                      | Wave |
|---------|--------------|----------------|--------------------------------|--------------------------------|------|
| {{JIRA_PROJECT_KEY}}-156 | {{PRIMARY_REPO_NAME}}  | {{JIRA_PROJECT_KEY}}-144 (done) | {{JIRA_PROJECT_KEY}}-144-regeneration-triggers  | {{JIRA_PROJECT_KEY}}-144-regeneration-triggers  | 1    |
| {{JIRA_PROJECT_KEY}}-158 | {{PRIMARY_REPO_NAME}}   | (none)         | develop                        | develop                        | 1    |
| {{JIRA_PROJECT_KEY}}-157 | {{PRIMARY_REPO_NAME}}  | {{JIRA_PROJECT_KEY}}-156 (batch)| (awaiting {{JIRA_PROJECT_KEY}}-156)             | (awaiting {{JIRA_PROJECT_KEY}}-156)             | 2    |
```

Key:
- `(done)` = blocker has an existing branch, ticket stacks on it
- `(batch)` = blocker is in this batch, ticket waits for it
- `(merged)` = blocker already merged to develop, no stacking needed

### D5. Worktree Creation with Resolved Bases

When creating worktrees, use the resolved base branch instead of always using `develop`:

```bash
# For tickets stacking on an existing branch:
mkdir -p {{STATE_ROOT}}/worktrees/<TICKET_ID>
cd {{CODEBASE_ROOT}}/<repo-name> && git worktree add -b <BRANCH_NAME> {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> <RESOLVED_BASE>

# For Wave 2+ tickets depending on a Wave 1 ticket in this batch:
# Wait for the dependency's subagent to complete, then:
cd {{CODEBASE_ROOT}}/<repo-name> && git worktree add -b <BRANCH_NAME> {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> <WAVE1_TICKET_BRANCH>

# Initialize codegraph in the new per-repo worktree (background, non-blocking):
codegraph init {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> 2>/dev/null \
  && cp {{CODEBASE_ROOT}}/.codegraph/config.json \
        {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name>/.codegraph/config.json 2>/dev/null \
  && nohup codegraph index {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo-name> \
       > /tmp/codegraph-init-<TICKET_ID>-<repo-name>.log 2>&1 &
```

**The subagent prompt must include the resolved BASE_BRANCH and PR_TARGET:**
```
BASE_BRANCH: <resolved_base>   ← may be a blocker's branch, not develop
PR_TARGET: <pr_target>         ← PR targets the base branch
```

### D6. Inter-Wave Handling

When tickets form waves within a batch:
1. Dispatch Wave 1 tickets in parallel (Phase 1)
2. Wait for ALL Wave 1 subagents to complete
3. Run orchestrator Phase 2 (Steps 7.5–11.5) for Wave 1 tickets
4. Use Wave 1 ticket branches as base for Wave 2 worktrees
5. Dispatch Wave 2 tickets (Phase 1)
6. Run Phase 2 for Wave 2 tickets
7. Continue until all waves complete Phase 1 + Phase 2
8. Run Phase 3 ONCE across all tickets (E2E testing)
9. Run Phase 4 ONCE (create PRs, final review, pipeline check)

This follows the same pattern as Epic Mode §E4 but applies to ad-hoc ticket batches.


## Epic Mode

When a provided ticket is an **Epic**, the standard single-ticket pipeline does not apply. Instead:

### E0. EPIC_MODE flag — default ON for any epic-parented work

As soon as Step 1 fetches issue metadata, set `EPIC_MODE=true` if EITHER condition holds:
1. The provided ticket is itself an **Epic** (issuetype.name == "Epic"), OR
2. The provided ticket has `parent.issuetype.name == "Epic"` (i.e. it's a child story of an Epic).

When `EPIC_MODE=true`, write a state file BEFORE dispatching any worker:

```bash
mkdir -p {{STATE_ROOT}}/epic-<EPIC_ID>
cat > {{STATE_ROOT}}/epic-<EPIC_ID>/state.json <<EOF
{"epic_id": "<EPIC_ID>", "epic_branch": "<EPIC_ID>-<slug>", "tickets": [...], "waves": [...]}
EOF
```

**Worker contract under EPIC_MODE:**
- Workers MUST NOT run `git push -u origin {{JIRA_PROJECT_KEY}}-...` (per-ticket push)
- Workers MUST NOT run `gh pr create`
- Phase 4 (consolidated PR per repo) is owned by the orchestrator — see [Epic PR Consolidation](#epic-pr-consolidation).
- Hook enforcement: `require-pipeline-complete.sh` and a PreToolUse hook on `Bash` should refuse `git push -u origin {{JIRA_PROJECT_KEY}}-` / `gh pr create` whenever `{{STATE_ROOT}}/epic-<EPIC_ID>/state.json` exists and the ticket is listed as a child of that epic.

**Failure {{JIRA_PROJECT_KEY}}-EX01 motivates this:** {{JIRA_PROJECT_KEY}}-EX01b worker created standalone PR #266 even though parent {{JIRA_PROJECT_KEY}}-EX01 was an Epic; the operator had to close it manually. With `EPIC_MODE` flag enforced, that PR creation is blocked at the hook layer.


### E1. Fetch Child Stories

Use Jira search to get all child issues of the epic:

```
mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql(
  jql: "parent = <EPIC_ID> ORDER BY created ASC"
)
```

For each child story, fetch full details (summary, description, issue type) to extract:
- The repo it belongs to (from a `[<repo>]` prefix in the summary — names from `repos.json` — or from description keywords). **Note:** if your frontend lives inside a backend repo rather than its own, map `[Frontend]` to that repo.
- Its blockers: parse `"Blocked by: <ID>"` lines from the description

Display a summary:
```
Epic: <EPIC_ID> — <title>
Found N child stories:
  {{JIRA_PROJECT_KEY}}-140  [{{PRIMARY_REPO_NAME}}]    Data model — record_item table         blockers: none
  {{JIRA_PROJECT_KEY}}-141  [{{PRIMARY_REPO_NAME}}] Data model — line_mode         blockers: none
  {{JIRA_PROJECT_KEY}}-142  [{{PRIMARY_REPO_NAME}}]    API — record items endpoints           blockers: {{JIRA_PROJECT_KEY}}-140
  {{JIRA_PROJECT_KEY}}-143  [{{PRIMARY_REPO_NAME}}] RecordProjectionService               blockers: {{JIRA_PROJECT_KEY}}-140, {{JIRA_PROJECT_KEY}}-141
  {{JIRA_PROJECT_KEY}}-144  [{{PRIMARY_REPO_NAME}}] Regeneration triggers                  blockers: {{JIRA_PROJECT_KEY}}-143
  {{JIRA_PROJECT_KEY}}-145  [{{PRIMARY_REPO_NAME}}]  Gateway external CRM/accounting connector sync from record items   blockers: {{JIRA_PROJECT_KEY}}-142
  {{JIRA_PROJECT_KEY}}-146  [Frontend]    Record viewer Detail View tab        blockers: {{JIRA_PROJECT_KEY}}-142    → {{PRIMARY_REPO_NAME}}
  {{JIRA_PROJECT_KEY}}-147  [Frontend]    Vendor settings dropdown               blockers: {{JIRA_PROJECT_KEY}}-141    → {{PRIMARY_REPO_NAME}}
```

### E2. Build Dependency Waves

Group stories into **waves** using topological sort:

- **Wave 1**: stories with no unresolved blockers
- **Wave 2**: stories whose blockers are all in Wave 1
- **Wave N**: stories whose blockers are all in Waves 1..N-1

Stories within the same wave are **independent** — they can run in parallel.
Stories in Wave N+1 must wait for all of Wave N to complete (PRs merged to `develop`).

**Print the wave plan before executing:**
```
Wave 1 (parallel): {{JIRA_PROJECT_KEY}}-140 [{{PRIMARY_REPO_NAME}}], {{JIRA_PROJECT_KEY}}-141 [{{PRIMARY_REPO_NAME}}]
Wave 2 (parallel): {{JIRA_PROJECT_KEY}}-142 [{{PRIMARY_REPO_NAME}}], {{JIRA_PROJECT_KEY}}-143 [{{PRIMARY_REPO_NAME}}]
Wave 3 (parallel): {{JIRA_PROJECT_KEY}}-144 [{{PRIMARY_REPO_NAME}}], {{JIRA_PROJECT_KEY}}-145 [{{PRIMARY_REPO_NAME}}], {{JIRA_PROJECT_KEY}}-146 [{{PRIMARY_REPO_NAME}}], {{JIRA_PROJECT_KEY}}-147 [{{PRIMARY_REPO_NAME}}]
```

**`[Frontend]` stories map to `{{PRIMARY_REPO_NAME}}`** — frontend code (React components, Dash pages, UI assets) lives inside the `{{PRIMARY_REPO_NAME}}` repo, not in a separate frontend repo. Always map `[Frontend]` prefixed stories to `{{PRIMARY_REPO_NAME}}`.

### E3. Branch Strategy

Branching rules depend on whether stories in the **same repo** are in consecutive waves:

#### Same-repo sequential stories (A blocks B, both in same repo)

B's branch must **chain** from A's branch, not from `develop`. Otherwise B lacks A's code.

```bash
# A branches from develop (Wave 1)
git -C <repo-path> worktree add -b <A_BRANCH> {{STATE_ROOT}}/worktrees/<A_ID>/<repo> develop

# B branches from A's branch (Wave 2)
git -C <repo-path> worktree add -b <B_BRANCH> {{STATE_ROOT}}/worktrees/<B_ID>/<repo> <A_BRANCH>
```

B's PR target is `<A_BRANCH>` — when A merges to `develop`, B's PR auto-retargets to `develop`.

#### Cross-repo dependencies (A in repo X blocks B in repo Y)

B still branches from `develop` in repo Y. No chaining needed — the cross-repo dependency means B will be developed _after_ A is merged.

```bash
# B branches from develop in its own repo
git -C <repo-Y-path> worktree add -b <B_BRANCH> {{STATE_ROOT}}/worktrees/<B_ID>/<repo-Y> develop
```

#### Summary table for {{JIRA_PROJECT_KEY}}-139

| Story | Repo | Branch from | PR targets |
|-------|------|-------------|-----------|
| {{JIRA_PROJECT_KEY}}-140 | {{PRIMARY_REPO_NAME}} | `develop` | `develop` |
| {{JIRA_PROJECT_KEY}}-141 | {{PRIMARY_REPO_NAME}} | `develop` | `develop` |
| {{JIRA_PROJECT_KEY}}-142 | {{PRIMARY_REPO_NAME}} | `{{JIRA_PROJECT_KEY}}-140-...` branch | `{{JIRA_PROJECT_KEY}}-140-...` (retargets to develop after {{JIRA_PROJECT_KEY}}-140 merges) |
| {{JIRA_PROJECT_KEY}}-143 | {{PRIMARY_REPO_NAME}} | `{{JIRA_PROJECT_KEY}}-141-...` branch | `{{JIRA_PROJECT_KEY}}-141-...` (retargets after {{JIRA_PROJECT_KEY}}-141 merges; uses {{PRIMARY_REPO_NAME}} develop for cross-repo dep) |
| {{JIRA_PROJECT_KEY}}-144 | {{PRIMARY_REPO_NAME}} | `{{JIRA_PROJECT_KEY}}-143-...` branch | `{{JIRA_PROJECT_KEY}}-143-...` |
| {{JIRA_PROJECT_KEY}}-145 | {{PRIMARY_REPO_NAME}} | `develop` | `develop` (cross-repo dep on {{JIRA_PROJECT_KEY}}-142) |
| {{JIRA_PROJECT_KEY}}-146 | {{PRIMARY_REPO_NAME}} | `develop` | `develop` (cross-repo dep on {{JIRA_PROJECT_KEY}}-142; `[Frontend]` = UI code in {{PRIMARY_REPO_NAME}}) |
| {{JIRA_PROJECT_KEY}}-147 | {{PRIMARY_REPO_NAME}} | `{{JIRA_PROJECT_KEY}}-141-...` branch | `{{JIRA_PROJECT_KEY}}-141-...` (same-repo chain; `[Frontend]` = UI code in {{PRIMARY_REPO_NAME}}) |

### E4. Wave Execution

Execute all waves **without pausing for merges**. Waves run sequentially (Wave 2 starts after Wave 1 subagents finish, not after PRs merge), but branch stacking (§E3) means each wave has all predecessor code available on its branch.

**Execution order:**

1. Dispatch Wave 1 stories in parallel (single message, multiple Task calls)
2. Wait for ALL Wave 1 subagents to complete
3. **Run orchestrator Phase 2 (Steps 7.5–11.5)** for all Wave 1 tickets before proceeding
4. **Run inter-wave migration coordination** (§E4.1) before dispatching the next wave
5. Dispatch Wave 2 stories in parallel — branch from Wave 1 branches (already set up in §E3)
6. Wait for ALL Wave 2 subagents to complete
7. **Run orchestrator Phase 2 (Steps 7.5–11.5)** for all Wave 2 tickets before proceeding
8. Continue until all waves are done (each wave: dispatch → wait → Phase 2 review)

**Phase 2 runs after EACH wave, not just at the end.** This ensures code quality issues are caught and fixed before dependent waves build on top of potentially buggy code. Phase 3 (E2E) and Phase 4 (PRs) still run once at the end after all waves complete.

**Wave-Level Phase 2 in Epic Mode (replaces per-ticket Phase 2):**

In `EPIC_MODE`, do NOT run Phase 2 once per ticket. Instead run **ONE** Phase 2 pass per wave against the merged wave diff:

```bash
# After all tickets in Wave N have merged into the consolidated epic branch:
PREV_TIP=$(cat {{STATE_ROOT}}/epic-<EPIC>/wave-$((N-1))-tip.sha 2>/dev/null || echo <BASE_BRANCH>)
CURR_TIP=$(git -C <repo> rev-parse <EPIC_BRANCH>)
echo "$CURR_TIP" > {{STATE_ROOT}}/epic-<EPIC>/wave-${N}-tip.sha

git -C <repo> diff "$PREV_TIP".."$CURR_TIP"   # ← THE Phase 2 review unit for this wave
```

Run Steps 7.5 (Simplify), 8 (Code Review), 9 (Bug Hunt), 10 (qbcheck), 11 (Fix), 11.5 (Verify) ONCE on this consolidated wave diff. The review unit is the merged behavioural change, not each child ticket.

Why: {{JIRA_PROJECT_KEY}}-EX01 had 4 pure-file-move tickets in Wave 1 — running Phase 2 four times produced 4× redundant reviews of the same logical change. The wave-level diff is the meaningful unit; per-ticket review of file moves is wasteful.

**Phase 2 mode selection:**
- `EPIC_MODE=false` (standalone tickets / ad-hoc batches) → per-ticket Phase 2 (existing behaviour)
- `EPIC_MODE=true` → wave-level Phase 2 (one pass per wave, against the consolidated wave diff)

**Wave N>1 base branch (EPIC_MODE):**

In `EPIC_MODE`, BASE_BRANCH for Wave N is the **consolidated epic branch** (`<EPIC_ID>-<slug>`) with Waves 1..N-1 already merged into it — NOT `develop`. This ensures Wave N workers see structural changes (file moves, schema migrations, new modules) introduced by earlier waves; otherwise they will plan against stale paths and produce conflicting diffs.

```
Wave 1 worker BASE_BRANCH: develop                  (or parent epic branch)
Wave 2 worker BASE_BRANCH: <EPIC_ID>-<slug>         (after Wave 1 merged)
Wave N worker BASE_BRANCH: <EPIC_ID>-<slug>         (after Waves 1..N-1 merged)
```

The orchestrator merges each wave's branches into `<EPIC_ID>-<slug>` BEFORE dispatching the next wave (see [Epic PR Consolidation](#epic-pr-consolidation) for the merge command). Failure {{JIRA_PROJECT_KEY}}-EX01 motivates this: Wave 2 workers in {{JIRA_PROJECT_KEY}}-EX01 were dispatched with `BASE_BRANCH=develop` and re-introduced files that Wave 1 had moved.

**Each wave's subagents receive the branch they must base their work on:**

```
Task prompt includes:
  - TICKET_ID: {{JIRA_PROJECT_KEY}}-142
  - WORKTREE_PATH: {{STATE_ROOT}}/worktrees/{{JIRA_PROJECT_KEY}}-142
  - BASE_BRANCH: {{JIRA_PROJECT_KEY}}-140-data-model-record-item   ← not develop!
  - PR_TARGET: {{JIRA_PROJECT_KEY}}-140-data-model-record-item     ← PR targets blocker branch
```

This means:
- All code is developed on a **stacked branch chain** — no merge required between waves
- PRs form a chain: {{JIRA_PROJECT_KEY}}-142 PR targets {{JIRA_PROJECT_KEY}}-140 branch → when {{JIRA_PROJECT_KEY}}-140 merges to develop, {{JIRA_PROJECT_KEY}}-142 PR auto-retargets to develop
- The whole epic can be implemented and reviewed without any intermediate merges

### E4.1 Inter-Wave Migration Coordination (CRITICAL)

**Problem:** When Wave N adds an alembic migration (new table, new column, new enum type), Wave N+1 stories in the **same repo** need `alembic upgrade head` to run before `alembic revision --autogenerate` can work. The database must reflect Wave N's schema changes before autogenerate can detect Wave N+1's changes.

**After each wave completes, the orchestrator checks:**

1. For each repo that had a story in the completed wave:
   ```bash
   # Check if the wave added any migration files
   git -C {{STATE_ROOT}}/worktrees/<WAVE_N_TICKET>/<repo> diff <BASE_BRANCH>..HEAD -- "alembic/versions/*.py"
   ```

2. If migrations were added AND the next wave has a story in the **same repo** that also needs a migration:
   - The next wave's story will need `alembic upgrade head` before autogenerate
   - Run `alembic upgrade head` in the worktree before dispatching the next wave's subagent

3. **Decision logic:**

   | Wave N added migration? | Wave N+1 needs migration in same repo? | Action |
   |------------------------|---------------------------------------|--------|
   | No | Any | No action needed |
   | Yes | No (code-only changes) | No action needed |
   | Yes | Yes | **Must apply Wave N migration first** |

4. **When migration coordination is needed:**
   - Run `alembic upgrade head` directly in the worktree:
     ```bash
     cd {{STATE_ROOT}}/worktrees/<NEXT_TICKET>/<repo>
     PYTHONPATH="<worktree-path>:<sibling-repo-paths>:$PYTHONPATH" \
       {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/venv/bin/python -m alembic upgrade head
     ```
   - Verify the upgrade succeeded before dispatching Wave N+1 subagents

5. **If Wave N's migration has bugs** (like the {{JIRA_PROJECT_KEY}}-141 enum type issue):
   - The orchestrator must fix the migration in Wave N's branch FIRST
   - Push the fix to Wave N's branch
   - Rebase Wave N+1's branch on the updated Wave N branch
   - Then ask user to run `alembic upgrade head`

6. **Tell the subagent about the DB state:**
   Add to the subagent prompt:
   ```
   DATABASE STATE: The database has been upgraded to include migrations from
   Wave N (<list of ticket IDs>). You can run `alembic revision --autogenerate`
   directly — the DB is at head for this repo.
   ```
   Or if no migration coordination was needed:
   ```
   DATABASE STATE: The database may NOT include parent branch migrations.
   If you need a migration, try autogenerate first. If it fails because the
   DB is not at head, STOP and report the error — do NOT hand-write a migration.
   ```

### E4.2 Cross-Branch Integration Review (CRITICAL)

**Problem:** Epic waves produce changes that depend on each other — across repos AND across stacked branches in the same repo. Each story's subagent only sees its own diff. Integration issues — broken FK assumptions, mismatched API contracts, schema drift, stale references to removed code — are invisible to single-story reviewers.

**This applies to TWO cases:**

| Case | Example | Why review context is needed |
|------|---------|------------------------------|
| **Cross-repo (same wave)** | {{JIRA_PROJECT_KEY}}-140 ({{PRIMARY_REPO_NAME}}) + {{JIRA_PROJECT_KEY}}-143 ({{PRIMARY_REPO_NAME}}) | the dependent repo writes to the primary repo's tables; must match its schema |
| **Same-repo cross-branch (stacked)** | {{JIRA_PROJECT_KEY}}-140 ({{PRIMARY_REPO_NAME}}, Wave 1) → {{JIRA_PROJECT_KEY}}-142 ({{PRIMARY_REPO_NAME}}, Wave 2) | {{JIRA_PROJECT_KEY}}-142 builds on {{JIRA_PROJECT_KEY}}-140's changes; reviewer needs both diffs |

**After each wave completes, the orchestrator checks for integration review triggers:**

1. **Detect integration review triggers:**
   ```
   Integration review is needed when ANY of these are true:
   a) The completed wave has stories in 2+ different repos (cross-repo)
   b) The completed wave has stories that stack on a previous wave's branch in the same repo (cross-branch)
   c) Cherry-picks or cross-branch integrations were done manually by the orchestrator

   If NONE are true → skip this section, proceed normally.
   ```

2. **Gather combined diffs from ALL related branches:**
   ```bash
   # Collect diffs from all stories in the current wave
   for each <TICKET_ID>/<repo> in the wave:
     cd {{STATE_ROOT}}/worktrees/<TICKET_ID>/<repo>
     git diff <BASE_BRANCH>..HEAD > {{STATE_ROOT}}/worktrees/wave-N-<TICKET_ID>-<repo>.diff

   # ALSO collect diffs from dependency branches that the wave builds on
   # (stacked branches from previous waves)
   for each dependency <DEP_TICKET>/<repo> that current wave depends on:
     cd {{STATE_ROOT}}/worktrees/<DEP_TICKET>/<repo>
     git diff <DEP_BASE_BRANCH>..HEAD > {{STATE_ROOT}}/worktrees/dep-<DEP_TICKET>-<repo>.diff
   ```

3. **Build combined context document:**
   Concatenate all diffs with clear headers showing the dependency chain:
   ```
   === DEPENDENCY: {{PRIMARY_REPO_NAME}} changes ({{JIRA_PROJECT_KEY}}-140, Wave 1) ===
   <diff from {{JIRA_PROJECT_KEY}}-140 {{PRIMARY_REPO_NAME}} branch>

   === CURRENT: {{PRIMARY_REPO_NAME}} changes ({{JIRA_PROJECT_KEY}}-142, Wave 2, stacked on {{JIRA_PROJECT_KEY}}-140) ===
   <diff from {{JIRA_PROJECT_KEY}}-142 {{PRIMARY_REPO_NAME}} branch>

   === CURRENT: {{PRIMARY_REPO_NAME}} changes ({{JIRA_PROJECT_KEY}}-143, Wave 2) ===
   <diff from {{JIRA_PROJECT_KEY}}-143 {{PRIMARY_REPO_NAME}} branch>
   ```

4. **Dispatch integration review agents:**
   Launch 3 agents in parallel (single message, multiple Task calls), each receiving the **combined** context:

   **Agent A: Contract & Schema Reviewer** (`feature-dev:code-reviewer`)
   ```
   Prompt: "You are reviewing changes across MULTIPLE branches/repos that must work together.
   The diffs are labeled as DEPENDENCY (previous wave) and CURRENT (this wave).

   Focus on integration correctness:
   - API contracts: Do callers match the endpoints they call? (URL paths, request/response shapes, HTTP methods)
   - FK references: Do foreign keys reference columns that actually exist in the other branch/repo's schema?
   - Schema alignment: Do ORM models, Pydantic schemas, and SQL queries agree on column names, types, and nullability?
   - Import paths: Do cross-repo imports resolve correctly?
   - Enum/constant consistency: Are shared enums and constants defined identically across branches?
   - Stacked branch coherence: Does the CURRENT branch correctly build on DEPENDENCY changes? (no stale references to removed/renamed code)

   Combined diffs:
   <COMBINED_DIFF_CONTEXT>"
   ```

   **Agent B: Data Flow Tracer** (`data-flow-analyzer`)
   ```
   Prompt: "Trace data as it flows BETWEEN these branches and repos.
   The diffs are labeled as DEPENDENCY (previous wave) and CURRENT (this wave).

   Focus on:
   - Data written by one branch/repo and read by another: are column names, JSON keys, and types consistent?
   - JSONB fields: if one branch writes row_metadata with certain keys, does the other read those exact keys?
   - ID resolution: if branch B uses an ID from branch A (e.g., core_order_id), is the lookup correct?
   - Null handling: if branch A can return NULL, does branch B handle it?
   - Stacked branch data flow: does the CURRENT branch's code correctly consume data structures introduced by DEPENDENCY?

   Combined diffs:
   <COMBINED_DIFF_CONTEXT>"
   ```

   **Agent C: Dependency & Ordering Checker** (`dependency-checker`)
   ```
   Prompt: "Verify that all cross-branch and cross-repo dependencies are satisfied.
   The diffs are labeled as DEPENDENCY (previous wave) and CURRENT (this wave).

   Focus on:
   - Does CURRENT code depend on DEPENDENCY's new tables/columns/endpoints?
   - Are there ordering constraints? (e.g., must DEPENDENCY's migration run before CURRENT's code works?)
   - If DEPENDENCY removes or renames something, does CURRENT still reference the old name?
   - Check alembic migrations across branches: do they create what the consuming code expects?
   - For same-repo stacked branches: does CURRENT's migration chain correctly from DEPENDENCY's migration?

   Combined diffs:
   <COMBINED_DIFF_CONTEXT>"
   ```

5. **Synthesize integration findings:**
   After all 3 agents return:
   - Deduplicate overlapping findings
   - Categorize as MUST FIX (broken integration) vs SHOULD FIX (potential issue) vs NOTE
   - Fix any MUST FIX issues in the relevant worktree before proceeding to PR creation
   - Report findings alongside per-story review results

6. **Integration with per-story steps 8-13:**
   Integration review runs IN ADDITION to per-story Steps 8-13, not as a replacement.
   The orchestrator should:
   - Run integration review (§E4.2) first
   - Fix any MUST FIX integration issues
   - Then run per-story Steps 8-13 for each story (code review, bug hunt, etc.)
   - Or run both in parallel if no integration issues are expected to block per-story review

### E5. Resuming Mid-Epic

When `/qship {{JIRA_PROJECT_KEY}}-139` is re-run after a partial run:

1. Fetch all child stories again
2. For each story, check `status.name` via Jira
3. Stories with status `Done` or `Closed` — skip; their branches are already merged into develop
4. Stories with status `In Progress` or with existing worktrees — resume from where they left off
5. For stories whose blocker has been merged to develop: they now branch from `develop` (no longer need the stacked branch — it merged)
6. Proceed from the first incomplete wave


#### Epic PR Consolidation

When running an epic, consolidate all story branches into a single branch per repo and create ONE PR per repo. This mirrors how epics are typically delivered (e.g., {{JIRA_PROJECT_KEY}}-219 had one branch with all changes, not 10 separate PRs).

**Step 12.1: Create consolidated epic branch per repo**

For each repo that had stories in this epic:

```bash
EPIC_ID="{{JIRA_PROJECT_KEY}}-245"
EPIC_SUMMARY="catalog-system-ui"
EPIC_BRANCH="${EPIC_ID}-${EPIC_SUMMARY}"
REPO_PATH="{{CODEBASE_ROOT}}/<repo-name>"

cd $REPO_PATH

# Start from the base branch (develop or parent epic branch)
git checkout <BASE_BRANCH> && git pull origin <BASE_BRANCH>

# Create the consolidated epic branch
git checkout -b $EPIC_BRANCH

# Merge each story branch in wave order (earliest first to preserve dependency order)
# Wave 1 stories first, then Wave 2, etc.
for STORY_BRANCH in <WAVE_1_BRANCHES> <WAVE_2_BRANCHES> <WAVE_3_BRANCHES>; do
  git merge --no-ff $STORY_BRANCH -m "merge: ${STORY_BRANCH} into ${EPIC_BRANCH}"
done
```

**Step 12.2: Resolve merge conflicts**

If merging story branches produces conflicts (common when multiple stories modify the same files like `index.js`, `component_wrapper.py`, `app.py`):
1. Resolve conflicts by keeping ALL changes from both sides (additive merges)
2. For `index.js` exports — keep all component exports
3. For `component_wrapper.py` — keep all wrapper functions
4. For `app.py` — keep all page registrations, nav entries, and badge configs
5. Run webpack build after resolving to verify the combined code works
6. Run tests to verify nothing broke

**Step 12.3: Push and create PR**

```bash
cd $REPO_PATH && git push -u origin $EPIC_BRANCH

gh pr create --title "${EPIC_ID} ${EPIC_TITLE}" --body "$(cat <<'EOF'
## Summary
- <bullet points covering ALL stories in this epic>

## Stories Included
| Story | Summary | Status |
|-------|---------|--------|
| {{JIRA_PROJECT_KEY}}-XXX | ... | Implemented |
| {{JIRA_PROJECT_KEY}}-YYY | ... | Implemented |

## Jira
${EPIC_ID}

## Test plan
- [ ] Unit tests pass (`pytest tests/ -v`)
- [ ] Webpack build passes (`npm run build`)
- [ ] Formatting passes (`black`, `isort`, `flake8`)
- [ ] E2E testing passed (see Phase 3 results)
EOF
)" --base <BASE_BRANCH>
```

**Step 12.4: Cleanup story branches**

After the consolidated PR is created, the individual story branches are no longer needed for PRs. They remain in the repo for reference but no separate PRs are created for them.

**When NOT to consolidate:**
- Standalone tickets (not part of an epic) — always create individual PRs
- Cross-repo stories where only ONE story touches a given repo — no consolidation needed, just create the single PR

