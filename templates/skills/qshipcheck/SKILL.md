---
name: qshipcheck
description: Validates that all orchestrator Phase 2 (review), Phase 3 (acceptance), and Phase 4 (deliver) steps were executed after qship pipeline completion. Run this after qship finishes to catch any skipped steps.
argument-hint: "[TICKET-ID or EPIC-ID]"
---

# qshipcheck — Pipeline Completion Validator

Verifies that the orchestrator's Phase 2 (review, bug hunt, fixes — per ticket), Phase 3 (E2E testing — once across all tickets), and Phase 4 (PR creation, final review, pipeline check — once across all tickets) were fully executed for a qship run. This is a hard gate — if any step was skipped, it must be run before the pipeline can be considered complete.

## ⛔ AUTONOMY & PERSISTENCE CONTRACT

**The qshipcheck report MUST end in one of two states: PASSED, or still running remediation.** There is no "FAILED — reporting incomplete" state. If you find missing steps, you run them, push any fixes, update the progress tracker, and loop back to Step 1 to re-verify. Repeat with no iteration cap until every row is VERIFIED.

Anthropic official guidance (verbatim):
> Never artificially stop any task early regardless of the context remaining.

This applies here: if context is tight during remediation, save progress to the progress tracker file and keep going — compaction is automatic.

## When to Run

Run `/qshipcheck <TICKET_ID>` after `/qship` finishes. The orchestrator should invoke this automatically as the very last step before the final completion message.

## What It Checks

### Phase 2 Steps (per ticket — static analysis)

| Step | What to verify | How to verify | Required evidence |
|------|---------------|---------------|-------------------|
| **7.5 Simplify** | `code-simplifier:code-simplifier` agent dispatched | Progress tracker + conversation | Agent dispatch tool call + result |
| **8 Code Review (Agents 1+2+4)** | 3 review agents dispatched | Progress tracker + conversation | 3 separate Task tool calls + results |
| **9 Bug Hunt** | 5 bug hunter agents dispatched | Progress tracker + conversation | 5 separate Task tool calls + results |
| **10 Bug Validation** | qbcheck ran on raw findings | Progress tracker + conversation | Validation summary (X real, Y false positive) |
| **11 Fix Issues** | Validated bugs were fixed | Git log + progress tracker | Fix commits OR "AUTO-PASS (0 real bugs)" |
| **11.5 Verification Gate** | Tests pass + formatting clean | Progress tracker | pytest output + black/isort check output |

### Phase 3 Steps (once across all tickets — dynamic validation)

| Step | What to verify | How to verify | Required evidence |
|------|---------------|---------------|-------------------|
| **14 E2E Testing** | `/qe2etest` was invoked (qe2etest traces the diff to triggers, drives API/worker/cron live, verifies DB, and delegates UI to `/qmanualt`) | Progress tracker + conversation | `/qe2etest` Skill tool call + test results (a `/qmanualt` invocation is acceptable supplementary evidence when qe2etest delegated UI work, but the primary signal MUST be `/qe2etest`) |

### Phase 4 Steps (once across all tickets — delivery)

| Step | What to verify | How to verify | Required evidence |
|------|---------------|---------------|-------------------|
| **12 Create PR** | PRs created for all affected repos | GitHub + progress tracker | `gh pr view` output for each PR |
| **13 Final Review** | `code-review:code-review` invoked on each PR | Progress tracker + conversation | Skill tool call + review posted on PR |

## Execution

### Step 1: Read Progress Tracker (Primary Source)

The orchestrator should have created a progress tracker file during Phase 2:

```
{{STATE_ROOT}}/worktrees/<TICKET_ID>/phase2-progress.md
```

Read this file first. If it exists, use it as the primary evidence source. Each row should show DONE with evidence.

If the file does NOT exist, fall back to conversation history scanning (Step 2).

**If the progress tracker shows any PENDING rows, those steps were skipped.**

### Step 2: Scan Conversation History (Secondary Source)

For each ticket in `$ARGUMENTS`, collect evidence from the conversation:

```
For each TICKET_ID:
  evidence = {}

  # Check 7.5: Look for code-simplifier agent dispatch
  evidence["7.5"] = search conversation for Task tool call with subagent_type "code-simplifier"
  # REQUIRED: Must find actual Task tool invocation, not just text mentioning it

  # Check 8: Look for 3 review agent dispatches
  evidence["8_agent1"] = search for Task tool call with "superpowers:code-reviewer" or production readiness
  evidence["8_agent2"] = search for Task tool call with "feature-dev:code-reviewer" or guidelines
  evidence["8_agent4"] = search for spec compliance review against Jira acceptance criteria
  # REQUIRED: Must find 3 separate Task tool invocations

  # Check 9: Look for 5 bug hunter dispatches
  evidence["9_agents"] = search for Task tool calls with these subagent_types:
    - root-cause-tracer
    - silent-failure-hunter
    - logic-error-detector
    - edge-case-hunter
    - race-condition-spotter
  # REQUIRED: Must find 5 separate Task tool invocations

  # Check 10: Look for qbcheck validation
  evidence["10"] = search for Skill tool call with "qbcheck" OR "Bug Validation" results
  # REQUIRED: Must find validation summary with counts

  # Check 11: Look for bug fixes
  if evidence["10"] shows real bugs (count > 0):
    evidence["11"] = search for git commits fixing them
  else:
    evidence["11"] = "AUTO-PASS (no real bugs found)"

  # Check 11.5: Look for verification gate
  evidence["11.5"] = search for pytest output + black/isort formatting check
  # REQUIRED: Must find actual command output, not just text claiming "tests passed"

  # Check 14: Look for qe2etest invocation (canonical Phase 3 entry point — qe2etest
  # delegates UI work to qmanualt, so a qmanualt-only invocation is NOT sufficient).
  evidence["14"] = search for Skill tool call with "qe2etest" + E2E test results
  # REQUIRED: Must find actual /qe2etest Skill invocation. A standalone "qmanualt" call
  # without a preceding "qe2etest" call is INSUFFICIENT — it means the diff-tracing,
  # API/worker/cron driving, and DB-verification work qe2etest owns was skipped.

  # Check 12: Look for PR creation
  evidence["12"] = search for gh pr create command output with PR URLs
  # REQUIRED: Must find actual PR URLs for each affected repo

  # Check 13: Look for final code review on PR
  evidence["13"] = search for Skill tool call with "code-review:code-review" + PR URL
  # REQUIRED: Must find actual Skill invocation with review posted on PR
```

### Step 3: Cross-Validate Evidence

**Do NOT trust claims without evidence.** For each step, verify:

1. **Tool call exists** — An actual Task/Skill/Bash tool call was made (not just text saying "I ran X")
2. **Result was received** — The tool call returned a result (not just dispatched and forgotten)
3. **Result was processed** — Findings were acted on (bugs fixed, issues addressed)

This prevents the failure mode where the orchestrator *says* it ran a step but actually skipped it.

### Step 4: Check PR State

For each PR created by qship:

```bash
# Get PR details
gh pr view <PR_NUMBER> --repo <REPO> --json state,reviewDecision,statusCheckRollup

# Check if review comments were posted (Step 13)
gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews
```

### Step 5: Report

Generate the verification report:

```
qshipcheck Report — <TICKET_ID>
=================================

Evidence Source: [Progress Tracker / Conversation Scan / Both]

Phase 2 Verification (per ticket — static analysis):
  Step 7.5  Simplify:           [VERIFIED / MISSING]  evidence: <tool call found/not found>
  Step 8    Review Agent 1:     [VERIFIED / MISSING]  evidence: <tool call found/not found>  (production readiness)
  Step 8    Review Agent 2:     [VERIFIED / MISSING]  evidence: <tool call found/not found>  (guidelines compliance)
  Step 8    Review Agent 4:     [VERIFIED / MISSING]  evidence: <tool call found/not found>  (spec compliance)
  Step 9    Bug Hunt:           [VERIFIED / MISSING]  evidence: <X/5 agents dispatched>
  Step 10   Bug Validation:     [VERIFIED / MISSING]  evidence: <X real, Y false positive>
  Step 11   Fix Issues:         [VERIFIED / MISSING / AUTO-PASS]
  Step 11.5 Verification Gate:  [VERIFIED / MISSING]  evidence: <tests: X passed, formatting: clean/dirty>

Phase 3 Verification (once across all tickets — dynamic validation):
  Step 14   E2E Testing:        [VERIFIED / MISSING]  evidence: <X/Y tests passed>

Phase 4 Verification (once across all tickets — delivery):
  Step 12   Create PR:          [VERIFIED / MISSING]  evidence: <PR URLs per repo>
  Step 13   Final Review:       [VERIFIED / MISSING]  evidence: <review posted on PR / not found>

Result: ALL STEPS VERIFIED  /  X STEPS MISSING
```

### Step 6: Remediate Missing Steps (LOOP UNTIL PASSED — no iteration cap)

If ANY step is marked `MISSING`:

1. **Report which steps were missed** with the specific evidence gap
2. **Run the missing steps NOW** — dispatch the required agents/skills directly
3. **Push any fixes** to the PR branch
4. **Update the progress tracker** with the remediation results
5. **Re-run verification** (go back to Step 1) to confirm all steps are now complete

**Do NOT skip remediation.** The whole point of qshipcheck is to catch and fix gaps before declaring the pipeline complete.

**Do NOT declare PASSED after remediation without re-verifying.** The re-verification must show ALL steps as VERIFIED.

**Loop-until-passed (no iteration cap).** If remediation creates new gaps (e.g., running Step 14 reveals bugs that need Step 11 fixes), remediate those too, push fixes, and re-verify. Keep looping. Never declare FAIL — declare "remediation in progress" and continue. The only terminal state is PASSED.

**Forbidden reasons to stop the loop:** "context is getting tight" (compaction is automatic), "this has run many iterations already" (there is no cap), "the issue is not my concern" (every gap in the evidence table is your concern).

### Step 7: Final Verdict

After all steps verified (including after remediation if needed):

```
qshipcheck PASSED — All Phase 2/3/4 steps verified for <TICKET_ID(s)>
```

Or if remediation was needed:

```
qshipcheck PASSED (after remediation) — X steps were missing, now complete:
  - Step 9 Bug Hunt: dispatched 5 agents, found 0 issues
  - Step 14 E2E Testing: invoked qe2etest (with UI delegated to qmanualt), 12/12 scenarios passed
```

## Integration with qship

The qship orchestrator should invoke `/qshipcheck` automatically as Step 15 (Phase 4):
- **After Phase 4 Step 13 (final review)** completes
- **Before the final "qship complete" message**

qshipcheck validates ALL three orchestrator phases:
- **Phase 2** (per ticket): Steps 7.5–11.5 ran for EVERY ticket
- **Phase 3** (once): Step 14 ran across all tickets
- **Phase 4** (once): Steps 12–13 ran (PRs created, final review posted)

This ensures the pipeline never completes with missing steps.

## Common Skip Patterns to Watch For

These are the most common ways steps get skipped — qshipcheck must catch all of them:

| Pattern | What happened | How to detect |
|---------|--------------|---------------|
| "Code looks clean" skip | Orchestrator skipped bug hunt because review found no issues | No Task tool calls for bug hunter agents |
| "Tests pass" skip | Orchestrator skipped E2E testing because unit tests passed | No Skill tool call for `/qe2etest` (a `/qmanualt`-only call still counts as a skip — qe2etest's diff-tracing + API/worker/cron drive was bypassed) |
| Partial bug hunt | Only 2-3 of 5 bug hunter agents dispatched | Fewer than 5 Task tool calls with bug hunter subagent_types |
| Claim without tool call | Text says "I ran the simplifier" but no Task tool call exists | No matching tool call in conversation |
| Context window pressure | Late steps dropped because context was running low | Progress tracker shows PENDING for later steps |
| Agent result ignored | Agent found issues but orchestrator didn't address them | Agent result shows findings but no follow-up commits |
| PR created too early | PR created before E2E testing (Phase 3) | Step 12 timestamp before Step 14 timestamp |
| Final review not on PR | Code review ran but didn't post on the actual PR | No `code-review:code-review` Skill call with PR URL |
