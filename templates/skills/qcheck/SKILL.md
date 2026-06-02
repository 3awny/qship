---
name: qcheck
description: Review code changes for correctness, security, and convention adherence — the general-purpose code reviewer. Use on a diff or recent changes before committing or opening a PR to catch bugs, risky patterns, and style violations; the central review step in the qship pipeline.
---

# Code Review

## Step 0: Apply Auto-Memory

The memory index is already loaded in your system prompt — no re-read needed. As you review, apply the relevant `feedback_*` entries (analogous code, redundancy patterns, qbcheck-before-reporting, actor-critic review, single-source-of-truth, etc.). When a finding maps to a known memory, cite the entry name in the report so the user can trace the rule.

If a specific memory file looks relevant to a finding, read just that one file from the auto-memory directory listed in the system prompt.

---

## Step 1: Gather Changes & Context

### 1.1 Get Git SHAs

```bash
BASE_SHA=$(git merge-base HEAD develop)
HEAD_SHA=$(git rev-parse HEAD)
```

If `git merge-base` fails (detached HEAD, or running on `develop`/`main`), STOP and ask the user for an explicit base — don't silently fall back to `HEAD~1`. Reviewing just the last commit on `develop` is almost never what's wanted; the user usually means a specific PR range, a Jira branch they forgot to switch to, or a tag.

### 1.2 Gather Diff

```bash
git diff --stat $BASE_SHA..$HEAD_SHA
git diff $BASE_SHA..$HEAD_SHA
```

Also check for unstaged/staged changes not yet committed:
```bash
git diff
git diff --cached
```

### 1.3 Read Guidelines

Read the review guidelines:
- **Project-level**: `CLAUDE.md` in the repository root
- **User-level**: `~/.claude/CLAUDE.md` (user preferences and lessons learned)

### 1.4 Identify What Was Built

Summarize from the diff and recent commits:
- What feature/fix was implemented
- Which files were changed and why
- The plan or requirements (if a plan file exists in `docs/plans/`)

---

## Step 2: Launch Parallel Review Agents

Deploy BOTH review agents simultaneously in a **single message** with two Task tool calls:

### 2.1 Superpowers Code Reviewer

Dispatch using the `superpowers:code-reviewer` subagent type:

```
Task(
  subagent_type: "superpowers:code-reviewer",
  description: "Comprehensive code review",
  prompt: |
    You are reviewing code changes for production readiness.

    Your task:
    1. Review: <WHAT_WAS_IMPLEMENTED>
    2. Compare against: <PLAN_OR_REQUIREMENTS> (or "No formal plan -- review based on code quality and correctness")
    3. Check code quality, architecture, testing
    4. Categorize issues by severity
    5. Assess production readiness

    What Was Implemented: <DESCRIPTION>
    Requirements/Plan: <PLAN_REFERENCE>
    Git Range: Base: <BASE_SHA>, Head: <HEAD_SHA>

    Run: git diff --stat <BASE_SHA>..<HEAD_SHA>
    Run: git diff <BASE_SHA>..<HEAD_SHA>

    Review Checklist:
    - Code Quality: separation of concerns, error handling, type safety, DRY, edge cases
    - Architecture: design decisions, scalability, performance, security
    - Testing: tests test logic (not mocks), edge cases covered, integration tests
    - Requirements: all plan requirements met, no scope creep, breaking changes documented
    - Production Readiness: migrations, backward compatibility, documentation

    Output Format:
    ### Strengths
    ### Issues (Critical / Important / Minor with file:line references)
    ### Recommendations
    ### Assessment: Ready to merge? [Yes/No/With fixes]
)
```

### 2.2 Feature-Dev Code Reviewer

Dispatch using the `feature-dev:code-reviewer` subagent type:

```
Task(
  subagent_type: "feature-dev:code-reviewer",
  description: "Guidelines compliance and bug detection review",
  prompt: |
    Review the code changes in this repository for bugs, logic errors, security vulnerabilities,
    code quality issues, and adherence to project conventions.

    Focus on:
    1. CLAUDE.md compliance -- read CLAUDE.md at the repo root and ~/.claude/CLAUDE.md
    2. Bug detection -- logic errors, null handling, race conditions, security vulnerabilities
    3. Code quality -- duplication, missing error handling, test coverage

    Git range to review: <BASE_SHA>..<HEAD_SHA>
    Run: git diff <BASE_SHA>..<HEAD_SHA>

    Rate each issue on confidence 0-100. Only report issues with confidence >= 80.
    Group by severity (Critical vs Important).
    For each issue: description, confidence score, file:line, guideline reference or bug explanation, concrete fix.
)
```

### 2.3 Spec Compliance Agent (when Jira ticket is available)

Detect a ticket from **two sources**, in order:

1. **Branch name** — `git branch --show-current` and grep for `[A-Z]+-[0-9]+`.
2. **Session context** — if the branch yields nothing, check whether a ticket was created via `/qnewticket` or referenced earlier in the chat. Use that key.

```bash
BRANCH=$(git branch --show-current)
TICKET_ID=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)
# If empty, prompt the user / check chat context for a recently-discussed ticket key
```

If a ticket ID is found (from either source), fetch its ACs via `getJiraIssue()` and dispatch:

```
Task(
  subagent_type: "feature-dev:code-reviewer",
  description: "Spec compliance review against Jira AC",
  prompt: |
    You are a SPEC COMPLIANCE reviewer. Your ONLY job is to verify that the code
    changes satisfy EVERY acceptance criterion from the Jira ticket.

    Jira Ticket: <TICKET_ID>
    Acceptance Criteria:
    <PASTE ACs FROM JIRA>

    Git range: <BASE_SHA>..<HEAD_SHA>
    Run: git diff <BASE_SHA>..<HEAD_SHA>

    For EACH acceptance criterion:
    1. Find the code that implements it (file:line)
    2. Verify it's functionally correct (not just present)
    3. Check edge cases specific to that AC

    Output:
    | AC # | Criterion | Implemented? | Location | Correct? | Notes |
    |------|-----------|-------------|----------|----------|-------|
    | AC1  | "..."     | YES/NO      | file:line | YES/PARTIAL/NO | ... |

    Final verdict: ALL ACs MET / X ACs MISSING
)
```

**If no ticket ID found on the branch**, skip this agent — the review proceeds with just the 2 general agents.

---

## Step 3: Analogous Code Check (CRITICAL -- Manual)

**While agents are running, perform this check yourself.** This is NOT delegated to agents because it requires deep codebase knowledge and semantic search.

### 3.1 Search for Analogous Code

**Before approving any new code, you MUST proactively search for and compare with analogous code:**

1. **Start with semantic search** (`mcp__claude-context-local__search_codebase`) to find conceptually related code
2. **Verify with grep/glob** if skeptical the semantic search missed something
3. Read the analogous code and extract the existing pattern

### 3.2 Compare Line-by-Line

For any new code, compare with the analogous implementation:
- SQL queries: all WHERE clauses, JOINs, filters (`is_active`, `tenant_id`, etc.)
- Method signatures: parameters, thresholds, return types
- Error handling patterns
- Data flow and structure

### 3.3 Flag Deviations

If your new code differs from analogous code, you MUST explain why. Default assumption: they should match.

### 3.4 No Redundant Mechanisms

- **Check for parallel code paths** -- If a new mechanism was added (callback, service, helper), verify there isn't an EXISTING mechanism that already does the same thing.
- **Ask "where does this already happen?"** -- Search for where similar functionality exists and whether extending that would be simpler.

### 3.5 Alembic Migration Validation — defer to /qmigrationdevcheck

If the diff touches `alembic/versions/`, **do not re-implement migration checks here** — invoke `/qmigrationdevcheck mode=qshipp2 <repo>` and fold its report into the Critical/Important sections (Step 4). That skill is the single source of truth for multi-head, missing-parent, cross-schema FK, merge-migration hygiene, cross-repo migration ordering, untrimmed drift, and orphaned tenant stamps.

Quick sanity flags this skill still owns (because they're cheap and don't need the full chain check):

- **Max one migration file per PR** — if more than one file under `alembic/versions/` is added, ask whether they should be combined.
- **Hand-written-looking migration** — random revision IDs and the autogenerate header comment are expected; sequential hex (`a1b2c3d4e5f6`, `b2c3d4e5f6a7`) and prose docstrings suggest the file was hand-rolled or LLM-generated. Flag for regeneration via `alembic revision --autogenerate`.

### 3.6 Documentation Staleness

After any structural change (new files, moved code, renamed modules), verify that `CLAUDE.md` and `docs/ARCHITECTURE.md` still reflect reality.

---

## Step 4: Synthesize Findings

After BOTH agents return, combine all findings into a unified review.

### 4.1 Deduplicate

Both agents may flag the same issue. Merge overlapping findings, keeping the more detailed description.

### 4.2 Combine Into Unified Report

```
Code Review Results
===================

## Strengths
[Merged from both agents -- what's well done]

## Issues

### Critical (Must Fix)
| # | Issue | Source | Confidence | File:Line | Fix |
|---|-------|--------|------------|-----------|-----|
| 1 | [description] | superpowers | -- | file:line | [how to fix] |
| 2 | [description] | feature-dev | 95 | file:line | [how to fix] |

### Important (Should Fix)
| # | Issue | Source | Confidence | File:Line | Fix |
|---|-------|--------|------------|-----------|-----|
| 1 | [description] | superpowers | -- | file:line | [how to fix] |

### Minor (Nice to Have)
| # | Issue | Source | File:Line |
|---|-------|--------|-----------|
| 1 | [description] | superpowers | file:line |

### Analogous Code Findings (Manual Check)
[Issues found from Step 3 -- pattern deviations, redundant mechanisms, migration issues, stale docs]

## Assessment
- **superpowers verdict**: [Ready to merge? Yes/No/With fixes]
- **feature-dev verdict**: [Clean / Issues found]
- **spec compliance**: [ALL ACs MET / X ACs MISSING / N/A (no ticket)]
- **Analogous code check**: [Pass / Issues found]
- **Overall**: [PASS / NEEDS FIXES]

Total: <N> critical, <M> important, <P> minor issues across all reviewers
```

### 4.3 Record Issues

Compile the final list categorized as:
- **MUST FIX** -- Critical from either agent, or analogous code violations
- **SHOULD FIX** -- Important from either agent
- **NOTE** -- Minor issues, observations

### 4.4 Validate Critical Findings with qbcheck (REQUIRED)

Before printing the report to the user, **run every Critical/MUST FIX finding through `/qbcheck`**. Memory `feedback_qbcheck_before_fixing` and `feedback_actor_critic_review` document that 30–50% of bug findings from automated reviewers are false positives — usually because the reviewer didn't trace the actual execution path or didn't realize a guideline doesn't apply in this context (e.g. the "single-assertion rule" not applying to mock objects or floats; see `feedback_check_base_classes`).

For each Critical finding:
1. Pass it to `/qbcheck` with the finding text + file:line + the reviewer's reasoning.
2. If qbcheck verdict is **false positive** → demote to NOTE with a "qbcheck: filtered" tag (don't drop silently — the user should still see it was raised).
3. If qbcheck verdict is **real** → keep as MUST FIX.
4. If **uncertain** → keep as MUST FIX with a "qbcheck: uncertain" tag so the user knows it warrants a closer look.

Do not run qbcheck on Important/Minor findings — the false-positive cost there is low and qbcheck has its own time cost.

---

## Step 5: Sequential Deep Analysis (Complex Changes Only)

For non-trivial changes (multi-file, complex logic, bug fixes), if either agent flagged uncertain areas:

### 5.1 Trace Data Flow

For each significant change:
1. Think through the change's implications sequentially
2. Trace the data flow -- where does input come from? Where does output go?
3. Consider edge cases -- empty inputs, nulls, race conditions, error states

### 5.2 Subagent Deep Dive (If Needed)

For complex logic or uncertain areas, spawn an Explore subagent. Brief it like a colleague who just walked into the room — generic prompts produce generic analysis. Include:

- **Specific file:line ranges** the subagent should focus on (don't say "the diff" — paste the relevant block).
- **The hypothesis you want tested** ("does this race with the existing webhook handler in `{{PRIMARY_REPO_NAME}}/services/external_crm_sync.py`?").
- **What you've already ruled out** so the subagent doesn't repeat your work.
- **The concrete questions** you need answered, not just "analyze deeply."

Template:

```
You are reviewing PR work on <BRANCH> in <REPO>. The diff at <FILE:LINES> changes
<WHAT>. I'm specifically worried about:

  1. <hypothesis 1, e.g. "callers in {{PRIMARY_REPO_NAME}}/external_crm_sync.py may pass stale party_ids
     because of the cache layer added in commit X">
  2. <hypothesis 2, e.g. "the new ON CONFLICT DO UPDATE drops org_id from the SET
     clause — same bug pattern as memory:feedback_upsert_on_conflict_columns">

I've already verified <X, Y> so don't re-check those.

Investigate by:
  - grep for callers of <FN_NAME> across every repo in `$SKILLS_ROOT/qship/repos.json`
  - read <SPECIFIC_FILE> and confirm <SPECIFIC_BEHAVIOR>
  - check whether the test in <TEST_FILE> exercises the new branch

Report under 300 words: confirmed bugs (file:line + 1-line repro), suspected bugs
(file:line + why uncertain), false alarms.
```

Use this when:
- The logic is complex enough that you might miss something
- You're unsure if all affected code has been updated
- The bug fix might need to be applied elsewhere (similar-pattern hunt)

---

## Output

Present the unified review report from Step 4 to the user. If there are MUST FIX issues, clearly list them as action items.
