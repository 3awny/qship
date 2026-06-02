---
name: qshipphasecheck
description: Hard gate between qship pipeline phases. Validates that ALL steps in the current phase completed before allowing the next phase to start. Run between Phase 2→3 and Phase 3→4 transitions. Blocks progression if ANY step was skipped — especially qbcheck (Step 10).
argument-hint: "<PHASE> <TICKET-ID...> e.g. phase2 {{JIRA_PROJECT_KEY}}-1 or phase3 {{JIRA_PROJECT_KEY}}-1 {{JIRA_PROJECT_KEY}}-2"
---

# qshipphasecheck — Inter-Phase Hard Gate

**This skill is a BLOCKING GATE. If it fails, the next phase MUST NOT start.**

Unlike `qshipcheck` (which runs at the end and can only report), `qshipphasecheck` runs BETWEEN phases and BLOCKS progression. It is the architectural enforcement layer that ensures no phase is skipped regardless of what the LLM thinks.

## ⛔ AUTONOMY & PERSISTENCE CONTRACT

A FAIL verdict is NOT a terminal state for the pipeline. It is an instruction to:

1. Dispatch the missing agents/skills for each FAIL row.
2. Wait for their results.
3. Re-run `/qshipphasecheck` for the same phase.
4. Repeat with no iteration cap until PASS.

Anthropic official guidance (verbatim):
> Never artificially stop any task early regardless of the context remaining.

The orchestrator MUST NOT skip to the next phase while this skill reports FAIL, and MUST NOT abandon the pipeline because a FAIL loop has run several rounds. Loop until PASS.

## When to Run

The qship orchestrator MUST invoke this at two transition points:

| Transition | Command | What it validates |
|------------|---------|-------------------|
| Phase 2 → Phase 3 | `/qshipphasecheck phase2 <TICKET_IDS>` | ALL Phase 2 steps (7.5–11.5) completed for EVERY ticket |
| Phase 3 → Phase 4 | `/qshipphasecheck phase3 <TICKET_IDS>` | Phase 3 (E2E testing) completed |

**If qshipphasecheck reports FAIL, the orchestrator MUST:**
1. Execute the missing steps
2. Re-run qshipphasecheck
3. Only proceed to the next phase after PASS

## Phase 2 Validation (phase2)

Read the progress tracker for EACH ticket:
```
{{STATE_ROOT}}/worktrees/<TICKET_ID>/phase2-progress.md
```

### Required Steps — ALL must be DONE:

| Step | Required Evidence | Why it can't be skipped |
|------|------------------|------------------------|
| 7.5 Simplify | Agent dispatch + result | Simplification before review reduces noise |
| 8 Review (3 agents) | 3 Task dispatches + results | Each reviewer checks different aspects |
| 9 Bug Hunt (5 agents) | 5 Task dispatches + results | Different bug types need different detectors |
| **10 qbcheck** | **Skill invocation + validation counts** | **Separates real bugs from false positives — Step 11 input depends on this** |
| 11 Fix Issues | Commits OR "0 real bugs" | Validated bugs must be fixed |
| 11.5 Verification | pytest output + formatting check | Confirms fixes didn't break anything |

### ⛔ Step 10 (qbcheck) — Special Enforcement

qbcheck is the SINGLE MOST IMPORTANT gate in Phase 2. Without it:
- False positives from Step 9 get "fixed", introducing unnecessary changes
- Real bugs get dismissed and ship to production
- Step 11 has no validated input

**Verification criteria for Step 10:**
```
1. Was the qbcheck skill invoked via the Skill tool? (not a manual approximation)
2. Did it receive raw findings from Step 9?
3. Does the evidence include:
   - Total raw findings count
   - Validated (real bug) count
   - Rejected (false positive) count
   - Do these numbers add up? (validated + rejected = total)
4. If Step 9 found 0 bugs: did qbcheck still run to confirm the "0" is genuine?
```

**If qbcheck evidence is missing or incomplete → HARD FAIL. Do not proceed.**

### Execution for Phase 2:

```
For each TICKET_ID in arguments:
  Read {{STATE_ROOT}}/worktrees/<TICKET_ID>/phase2-progress.md

  missing = []
  for each step in [7.5, 8, 9, 10, 11, 11.5]:
    if step status != "DONE" or evidence is empty:
      missing.append(step)

  # Special qbcheck deep validation
  if step 10 is DONE but evidence lacks validation counts:
    missing.append("10 (incomplete — missing validation counts)")
```

### Report:

```
qshipphasecheck Phase 2 — <TICKET_ID>
=======================================
Step 7.5  Simplify:          [PASS / FAIL]  evidence: <summary>
Step 8    Review (3 agents): [PASS / FAIL]  evidence: <3/3 dispatched>
Step 9    Bug Hunt (5 agents):[PASS / FAIL]  evidence: <5/5 dispatched>
Step 10   qbcheck:           [PASS / FAIL]  evidence: <X raw → Y real, Z false positive>  ⛔ HARD GATE
Step 11   Fix Issues:        [PASS / FAIL]  evidence: <commits / 0 real bugs>
Step 11.5 Verification:      [PASS / FAIL]  evidence: <tests: X passed, formatting: clean>

Result: PASS — Phase 3 may proceed
   OR: FAIL — X steps missing. Execute them before re-running this check.
        Missing: [list of missing steps]
        ⛔ BLOCKED: Do NOT start Phase 3 until this check passes.
```

## Phase 3 Validation (phase3)

Validates E2E testing was actually performed.

### Required Steps:

| Step | Required Evidence | Why it can't be skipped |
|------|------------------|------------------------|
| 14 E2E Testing | `/qe2etest` Skill invocation + results (qe2etest traces the diff to triggers, drives API/worker/cron live, verifies DB, and delegates UI to `/qmanualt`) | Unit tests don't catch integration issues, UI rendering bugs, or cross-service failures |

### Verification:
```
1. Was the qe2etest skill invoked via the Skill tool? (NOT just qmanualt — a qmanualt-only
   invocation means qe2etest's diff-tracing + API/worker/cron drive was skipped.)
2. Did it produce test results (HTTP evidence, DB-state assertions, plus screenshots
   from the qmanualt delegation when UI was in scope)?
3. Were the tests run against the ACTUAL changed code (not stale)?
```

### Report:

```
qshipphasecheck Phase 3 — <TICKET_IDS>
=======================================
Step 14   E2E Testing:       [PASS / FAIL]  evidence: <qe2etest invoked (UI delegated to qmanualt), X scenarios, evidence at path>

Result: PASS — Phase 4 may proceed
   OR: FAIL — E2E testing was not performed.
        ⛔ BLOCKED: Do NOT start Phase 4 (PR creation) until E2E testing passes.
        Run: /qe2etest to execute E2E tests, then re-run /qshipphasecheck phase3
```

## Integration with qship SKILL.md

The orchestrator's execution flow becomes:

```
Phase 1 (subagent): Steps 1-7.4
    ↓
Phase 2 (orchestrator): Steps 7.5-11.5
    ↓
/qshipphasecheck phase2 <TICKETS>  ← HARD GATE
    ↓ (only if PASS)
Phase 3 (orchestrator): Step 14
    ↓
/qshipphasecheck phase3 <TICKETS>  ← HARD GATE
    ↓ (only if PASS)
Phase 4 (orchestrator): Steps 12-13, 15
```

**The orchestrator MUST invoke this skill. It is not optional.**
**If it returns FAIL, the orchestrator MUST fix the missing steps and re-run.**
**The orchestrator MUST NOT rationalize skipping this check.**
