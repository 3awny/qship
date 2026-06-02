---
name: qplan
description: Review an implementation plan before any code is written — checks it against the actual codebase for missing steps, wrong assumptions, ignored existing patterns, and unhandled edge cases. Use after drafting a plan/TRD and before implementing; qship runs it as Step 6.
---

# Plan Review

Review a proposed implementation plan against the codebase and surface gaps, risks, and pattern violations **before any code is written**. The output is a verdict + a punch list of changes the plan author should make — not a rewrite of the plan.

This is a reviewer, not a drafter. If no plan exists yet, ask the user for one (or for the Jira ticket / spec) before proceeding. Don't invent a plan and then "review" it — that defeats the purpose.

## Inputs

Before reviewing, confirm what you're reviewing:

- **The plan** — a written plan in conversation, a markdown file, a Jira ticket description with steps, a Confluence page, or "the approach we just discussed". If unclear, ask.
- **The source of truth for requirements** — Jira ticket, spec, bug report, or user goal. Needed for the coverage check below. If absent, note it and skip the AC table.
- **Scope hints** — repos affected, branches in flight, deadlines. Ask only if non-obvious.

If the plan is too vague to review (e.g. "I'll add an endpoint and a UI"), say so and ask the author to flesh it out before you can usefully review.

## Memory

`MEMORY.md` is already loaded by the auto-memory system — don't re-read it. Just check if any loaded entry is relevant (planning patterns, cross-repo gotchas, analogous-code lessons) and apply it. If a memory entry directly contradicts something in the plan, call it out in the review with a citation.

## What a good plan looks like (the rubric)

Apply each of these to the plan. For every miss, add a row to the punch list with the specific change the author should make.

### 1. Analogous code was found and matched

The strongest signal a plan is grounded is that it points at an existing, similar implementation and proposes to follow it. If the plan doesn't cite an analogue, the author probably hasn't looked.

**How to check**: Search the codebase yourself for similar features (semantic search via `mcp__claude-context-local__search_codebase`, then verify with `grep` if you're skeptical). If you find an analogue the plan ignores, that's a finding — the plan should adopt the existing patterns (filters like `is_active`, tenant scoping, error handling, return shapes, thresholds) unless it explicitly justifies why it diverges.

**Why this matters**: The most expensive mistakes come from re-deriving a pattern that already exists, then getting one detail wrong (a missing filter, a different threshold, an inconsistent return type). The existing code is the source of truth.

### 2. The plan extends, doesn't parallel

If the new functionality already happens *somewhere* in the codebase — even partially — the plan should extend that path, not introduce a sibling path. Parallel mechanisms drift, duplicate bugs, and create N+1-style surprises.

**How to check**: For each new "callback" / "service" / "helper" the plan introduces, ask "where does this kind of thing happen today?" If the answer is "in module X already", flag it: the plan should modify X, not add a peer.

### 3. Acceptance criteria coverage (when applicable)

If there's a Jira ticket or spec with acceptance criteria, build this table and put it in the review:

```
| AC # | Acceptance Criterion          | Plan Step(s)        | Test Strategy             |
|------|-------------------------------|---------------------|---------------------------|
| AC1  | "User can create X"           | Step 3              | Unit + E2E                |
| AC2  | "Badge shows count"           | Step 5              | Integration + Playwright  |
| AC3  | "Cancel reverts state"        | MISSING             | —                         |
```

Every AC must map to at least one step. Every step should serve at least one AC (or have a stated reason — e.g. "preparatory refactor"). If there's no spec, skip the table and note that there's no external requirement to verify against.

### 4. Test strategy per step

Every step that adds or changes code names *what* will be tested and *how*. "Add tests" is not a strategy.

| Code change                     | Expected test strategy in the plan                              |
|---------------------------------|------------------------------------------------------------------|
| New API endpoint                | Unit test on handler + integration test on full request cycle    |
| New DB model / migration        | Migration up/down + model constraint + relationship tests        |
| New UI component / callback     | Playwright E2E covering render + the interaction                 |
| Bug fix                         | Regression test that fails on `main` and passes after the fix    |
| Pure refactor (no behavior δ)   | Existing tests must pass; no new tests needed                    |

If a step has no test strategy and isn't a pure refactor, that's a finding.

### 5. Risk assessment

Walk this checklist against the plan. Anything `YES` should already be addressed in the plan; if it's not, add a finding.

| Risk                          | Trigger                                                         | What the plan should include                                                |
|-------------------------------|-----------------------------------------------------------------|------------------------------------------------------------------------------|
| Cross-repo impact             | Touches an interface used by your repos / `{{PRIMARY_REPO_NAME}}` | Companion update steps in each affected repo, or explicit "no caller change needed" rationale |
| Migration risk                | Adds / alters DB tables or columns                              | Up + down migration, data backfill plan if needed, deploy ordering           |
| API contract change           | Modifies request or response shape                              | Enumeration of every consumer (UI, gateway sync, external) and how each is updated |
| Shared function change        | Edits a function with multiple callers                          | List of callers + how each remains correct                                   |
| Hot-path performance          | Adds queries to badge callbacks, list endpoints, login flow     | Index plan or measured rationale that the cost is acceptable                 |
| Cache invalidation            | Adds a cache layer or modifies cached data                      | Every mutation path that must invalidate, listed explicitly                  |

### 6. Sequencing and reversibility

A good plan orders steps so each one leaves the system in a working state, and risky/irreversible work happens last (or behind a flag). Flag plans that:
- Ship a migration before the code that uses it (or vice versa) without a deploy ordering note.
- Delete or rename a public symbol without a deprecation step.
- Bundle a refactor with a behavior change in the same step (makes review and revert harder).

### 7. Stated assumptions

The plan should explicitly list what it's *assuming* about the system (e.g. "assume `is_active` is the only soft-delete flag", "assume there's exactly one matcher per entity"). Unstated assumptions are the #1 source of plan failure. If a plan reads as if everything is known, push back: ask the author to articulate what they're guessing.

## Deep dive (use sparingly)

For non-trivial plans — multi-file, architectural, or fixes where the root cause is uncertain — go further:

- **Spawn Explore subagents** for specific questions: "Find every caller of `X` across all three repos", "Map the data flow from record ingest to reference match", "Confirm whether `Y` is reached when the user does `Z`". Don't run the whole review through subagents; use them for the questions you can't answer cheaply.
- **Verify assumptions, don't accept them.** If the plan says "this only runs once per request", check it. If it says "no other code touches this table", grep for the table name.
- **Synthesize before finalizing.** Once subagent findings are back, decide which ones change the verdict and which are noise. Don't dump raw findings into the review.

## Output format

Produce the review as the last message — concise, scannable, and actionable.

```
## Plan Review: <one-line subject>

**Verdict:** Approve | Approve with revisions | Needs significant revisions | Cannot review (missing info)

**Summary** (2–3 sentences on the overall shape — what's strong, what's the biggest gap)

### Findings
1. **[Severity]** Short title — what's wrong, where in the plan, what to change. Cite file paths or AC numbers where relevant.
2. ...

### AC coverage
<the table from rubric §3, or "N/A — no external spec">

### Open questions for the author
- ...
```

**Severity scale**: `Blocker` (plan will fail or ship broken if shipped as-is), `Major` (significant rework needed), `Minor` (worth fixing but not load-bearing), `Nit` (preference / polish).

Order findings by severity. Don't pad — if there are no Major issues, say so.

## When to push back instead of reviewing

- Plan is too vague to assess → ask for specifics on the steps that matter most.
- Plan is for a problem that hasn't been root-caused (e.g. fix proposed before the bug is understood) → say so; recommend `/qbug` or systematic-debugging first.
- Plan contradicts a memory entry the user has already endorsed → cite the memory, don't re-litigate.
- You don't have access to the codebase or the requirements → say what you'd need to do a real review.

A "looks fine 👍" review is almost always wrong. If you can't find anything, you probably haven't looked at the analogue code yet.
