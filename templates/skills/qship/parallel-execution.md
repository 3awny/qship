# Parallel Execution

Instructions for processing multiple Jira tickets simultaneously. Each ticket runs the full pipeline (pipeline-steps.md) in an isolated git worktree via a dedicated subagent.

> **Epic mode note:** When invoked from Epic Mode (SKILL.md §E4), this file applies to a single wave of stories only. Stories in different waves are NOT dispatched in parallel — they run in separate invocations after each wave's PRs are merged. See SKILL.md §E4 for the wave execution and pause-between-waves protocol.

---

## 1. Worktree Creation

For EACH ticket, create an isolated worktree from the monorepo:

```bash
cd {{CODEBASE_ROOT}} && git worktree add {{STATE_ROOT}}/worktrees/<TICKET_ID> develop
```

- Base directory: `{{STATE_ROOT}}/worktrees/`
- Each worktree gets its own copy of the full monorepo (repos in your repos.json are subdirectories, NOT git submodules)
- If worktree creation fails (e.g., branch already checked out, dirty state), log the error and skip that ticket -- do not block the others

Verify each worktree was created:
```bash
ls {{STATE_ROOT}}/worktrees/<TICKET_ID>/{{PRIMARY_REPO_NAME}}
```

**Initialize codegraph in the new worktree (background — non-blocking):**
```bash
codegraph init {{STATE_ROOT}}/worktrees/<TICKET_ID> 2>/dev/null \
  && cp {{CODEBASE_ROOT}}/.codegraph/config.json \
        {{STATE_ROOT}}/worktrees/<TICKET_ID>/.codegraph/config.json 2>/dev/null \
  && nohup codegraph index {{STATE_ROOT}}/worktrees/<TICKET_ID> \
       > /tmp/codegraph-init-<TICKET_ID>.log 2>&1 &
```
Why: subagent's `codegraph_*` MCP tools resolve from the worktree's `.codegraph/`. Without this they either fall back to the parent index (wrong file paths) or report "not initialized". Failure here is non-fatal — the pipeline still works without semantic search.

---

## 2. Subagent Dispatch

Launch ALL subagents in a **single message** with multiple Agent tool calls, each with `run_in_background: true`. This is critical for:
- **True parallelism** — if you send them in separate messages, they run sequentially
- **Orchestrator monitoring** — background agents let the orchestrator check output files, detect stubs, and SendMessage to running agents

For EACH ticket, spawn one background subagent:

```
Agent tool call:
  subagent_type: "general-purpose"
  mode: "bypassPermissions"
  run_in_background: true
  prompt: |
    Read these two files in full before doing anything (they're authoritative):
      1. ~/.claude/skills/qship/references/autonomy-contract.md
         — persistence rules, no-skip rule, local-DB pre-auth, anti-drift discipline
      2. ~/.claude/skills/qship/pipeline-steps.md
         — every step you execute, with the completion-report template at the top

    Your task: implement Jira ticket <TICKET_ID> end-to-end (Phase 1 + Phase 1.5;
    Phase 2 onward is deferred to the orchestrator and you record those rows as
    [DEFERRED]).

    Worktree path:        {{STATE_ROOT}}/worktrees/<TICKET_ID>
    Ticket ID:            <TICKET_ID>
    Substitute these everywhere pipeline-steps.md says <WORKTREE_PATH> / <TICKET_ID>.

    What "execute a step" means is in pipeline-steps.md and autonomy-contract.md.
    Headline: skill steps go through the Skill tool, agent steps go through the
    Task tool, no "simplified self-review" substitutions, no skipping. Subagents
    cannot dispatch nested Task agents — those steps are deferred per the
    completion-report template.

    Output: the PIPELINE EXECUTION REPORT checklist from pipeline-steps.md,
    with [DONE], [BLOCKED <reason>], or [DEFERRED] for every row.
```

**Subagents have Read access** — point them at the two files via absolute path (above) instead of pasting their contents into the prompt. The earlier "paste pipeline-steps.md verbatim" pattern wasted ~2k tokens × N tickets × N iterations and broke the moment pipeline-steps.md was edited (subagents would see a stale copy).

**Enforcement:** The orchestrator verifies each subagent's completion report includes the PIPELINE EXECUTION REPORT checklist. Any step shown as skipped without a valid blocking error is flagged and the orchestrator re-runs the missing steps itself.

---

## 2.1 Orchestrator-Run Steps (Two-Phase Architecture)

**CRITICAL:** Subagents cannot spawn nested subagents (Task tool is blocked by design in Claude Code — see [GitHub Issue #4182](https://github.com/anthropics/claude-code/issues/4182)). Steps that require dispatching agents via the Task tool MUST be run by the orchestrator.

### Steps the subagent runs (Phase 1):
- Steps 1-7.4: Jira fetch, repo detection, branch, plan, implement, directory check, clean
- Step 8 Agent 3: qcheckt skill (Skill tool works in subagents)
- Step 12: Create PR (commit, push, gh pr create)
- Step 13: Final review (code-review:code-review skill — Skill tool works)

### Steps the orchestrator runs (Phase 2 — after subagent completes):
- **Step 7.5**: Dispatch `code-simplifier:code-simplifier` agent
- **Step 8 Agents 1+2+4**: Dispatch `superpowers:code-reviewer` + `feature-dev:code-reviewer` + **spec compliance reviewer** agents
- **Step 9**: Dispatch 5 bug hunter agents (root-cause-tracer, silent-failure-hunter, logic-error-detector, edge-case-hunter, race-condition-spotter)
- **Step 10**: Validate bug findings (qbcheck — orchestrator does this itself)
- **Step 11**: Fix validated issues using **systematic debugging** (root cause → pattern analysis → smallest fix)
- **Step 11.5**: **Verification gate** — fresh pytest + formatting check; hard gate before PR creation

### Orchestrator Phase 2 Execution Flow:

After EACH subagent completes with a PR:

1. Get the diff from the subagent's worktree:
   ```bash
   cd <WORKTREE_PATH>/<repo-name> && git diff <BASE_BRANCH>..HEAD
   ```

2. Dispatch Steps 7.5 + 8 (agents 1+2+4) + 9 in a **single message** (up to 9 parallel agents, all with `run_in_background: true`):
   - 1x code-simplifier
   - 1x superpowers:code-reviewer
   - 1x feature-dev:code-reviewer
   - 1x spec compliance reviewer (compares diff against Jira acceptance criteria)
   - 5x bug hunters

3. After all agents return:
   - Run Step 10 (qbcheck validation) on combined findings
   - Run Step 11 (fix validated issues using systematic debugging) in the worktree
   - Run Step 11.5 (verification gate — fresh pytest + formatting check)
   - Only if Step 11.5 passes: push fixes to the PR branch

This two-phase approach ensures all review and bug-hunting steps actually run with specialized agents, rather than being self-reviewed by the subagent.

---

## 3. Result Collection & Pipeline Compliance Verification

After ALL subagents complete AND orchestrator Phase 2 is done:

### 3.1 Verify Pipeline Compliance

For EACH subagent's result, check that the PIPELINE EXECUTION REPORT checklist is present. Specifically verify:

1. **Steps 7.4 (qclean), 13 (final review)** are marked [DONE] by the subagent
2. **Steps 7.5, 8 (agents 1+2), 9, 10, 11** are marked [DEFERRED TO ORCHESTRATOR] — the orchestrator ran these
3. Each [DONE] step cites the actual skill/agent invoked (not "self-reviewed" or "simplified")
4. If ANY non-deferred steps show [SKIPPED] without a valid blocking error, mark that ticket as **INCOMPLETE**

**For INCOMPLETE tickets**, the orchestrator MUST:
1. Report which steps were skipped
2. Run the missing steps itself (dispatch the agents/skills directly) using the subagent's worktree
3. Fix any issues found by the missing steps
4. Update the PR with fixes

This is the enforcement mechanism — subagents know their work will be verified and missing steps will be caught.

### 3.2 Display Summary

Display a summary table:

```
| Ticket   | Branch                          | PR URL                              | Status   |
|----------|---------------------------------|--------------------------------------|----------|
| {{JIRA_PROJECT_KEY}}-1    | {{JIRA_PROJECT_KEY}}-1-add-vendor-endpoint       | https://github.com/.../pull/42       | Success  |
| {{JIRA_PROJECT_KEY}}-2    | {{JIRA_PROJECT_KEY}}-2-fix-sync-timeout          | https://github.com/.../pull/43       | Success  |
| {{JIRA_PROJECT_KEY}}-3    | {{JIRA_PROJECT_KEY}}-3-update-ocr-pipeline       | (none)                               | FAILED   |
```

For any ticket with multiple affected repos, list each PR on its own row:

```
| {{JIRA_PROJECT_KEY}}-1    | {{JIRA_PROJECT_KEY}}-1-add-vendor-endpoint       | {{PRIMARY_REPO_NAME}}: .../pull/42                 | Success  |
| {{JIRA_PROJECT_KEY}}-1    | {{JIRA_PROJECT_KEY}}-1-add-vendor-endpoint       | {{PRIMARY_REPO_NAME}}: .../pull/43 | Success  |
```

If a subagent reported failures, include the error summary beneath the table.

---

## 4. Cleanup

After all results are collected and reported, remove each worktree:

```bash
cd {{CODEBASE_ROOT}} && git worktree remove {{STATE_ROOT}}/worktrees/<TICKET_ID>
```

Then clean up the base directory if empty:
```bash
rmdir {{STATE_ROOT}}/worktrees 2>/dev/null
```

If a worktree removal fails (e.g., uncommitted changes), warn the user and provide the manual cleanup command.

---

## 5. Error Handling

- **Single ticket failure:** Report the failure in the summary table but let all other tickets continue. Never abort the batch for one failure.
- **Worktree creation failure:** Skip that ticket entirely. Report it as `SKIPPED` with the reason (e.g., "branch conflict", "disk full").
- **All tickets fail:** Display the full error summary for every ticket and suggest the user check `git worktree list` and `git status` for conflicts.
- **Subagent timeout or crash:** Mark the ticket as `FAILED` and include whatever partial output was returned.
