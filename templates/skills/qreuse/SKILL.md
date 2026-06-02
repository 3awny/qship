---
name: qreuse
description: Review a change for reuse opportunities — did it reinvent something that already exists in the codebase, and is new code factored so it can be reused. Use after implementing to catch duplicated logic and surface existing helpers/utilities you should call instead; part of qship's simplify/review pass.
---

# Code Reuse / Reusability Review

You are a code-reuse inspector. For new code being added, find existing implementations that already provide the same or near-same behavior, and decide between three outcomes: **reuse**, **extract**, or **deliberate duplication**. The framing is decision-oriented — not "always consolidate."

## Scope

Default to **the diff under review** (`git diff develop...HEAD` or staged). Look at every newly-added function, helper, service method, repository method, hook, or UI component. The point is to catch duplication *as it's being introduced*, before it ships. Whole-repo audits are an opt-in (`--full`) — they generate too much noise to be a useful default.

## Search method (required)

Your global CLAUDE.md mandates semantic search first. Apply that here:

1. **Semantic search** — `mcp__claude-context-local__search_codebase` with the new function/component's intent (not just its name). For each new symbol, search for two phrasings: what it *does* and what it *operates on*.
2. **Grep verification** — when semantic search returns a candidate, grep for the symbol name and adjacent ones (`Grep`/`rg`) to confirm it exists and is current. Semantic results can be stale or imprecise.
3. **Analogous-file scan** — your global CLAUDE.md "Analogous Code Discovery" rule: for any matcher/repo/service, look for sibling files with parallel names (e.g., `account_matcher` ↔ `record_matcher`). The analogue is the source of truth.

If you can't name the search query you ran, you can't claim a gap exists.

## The three outcomes

For each new symbol in the diff, decide:

### 1. Reuse — existing implementation already covers it
Import/call the existing one and delete the new copy. Cite file:line of the existing version.

### 2. Extract — multiple call sites diverging on the same idea
Create a shared helper, update all call sites. Three similar implementations is the minimum threshold (your global CLAUDE.md: "Three similar lines is better than a premature abstraction"). Don't extract from two.

### 3. Deliberate duplication — keep separate, justify why
Sometimes a "specialized variant" is correct and extending the shared function is wrong (memory: `feedback_specialized_functions`). Reasons that justify keeping separate code:

- The shared function would grow conditional flags for each caller (signal: parameters named `mode=`, `kind=`, `is_X=` proliferating).
- Two domains share a syntactic pattern but have different invariants — collapsing them couples unrelated change reasons.
- One caller is at a stable boundary (public API, migration) where stability is worth more than DRY.

When you choose duplication, say so explicitly with the reason. Silent duplication is the failure mode this skill exists to catch.

## {{COMPANY_SLUG}}-specific patterns to check

These come up repeatedly in your memory; check them by default:

- **Matcher symmetry** — new matchers in {{PRIMARY_REPO_NAME}} should mirror sibling matchers (record_matcher ↔ account_matcher). Same pattern: `is_active = true` filter, JOINs, threshold, return type.
- **Shared cross-component hooks** — when 2+ React components duplicate a fetch or check, extract to a shared module with module-scope cache + pure fns + hook wrappers (memory: `feedback_shared_cross_component_hooks`).
- **Generic vs feature-specific** — before shipping a new endpoint/table/component, check if a generic version is worth building (memory: `feedback_prefer_generic_over_feature_specific`).
- **Don't add a parallel mechanism** — global CLAUDE.md "Extend Existing Mechanisms": new callback when matchers already handle it, parallel loader when service exists, new validator when utility exists. Always extend the existing path.
- **Repo owns persistence** — service-layer code re-implementing what the repo's `create()` already does (with its embedding/dedup side-effects) is a reuse failure, not a refactor (memory: `feedback_repo_owns_persistence`).

## Verify before reporting

For each "existing implementation found" finding:

1. Open the cited file:line and confirm the function still exists and matches the new code's intent (signature, behavior, side-effects).
2. Check for invariants the new caller might not satisfy — different tenant scoping, different soft-delete semantics, different return shape.
3. If the existing implementation has known bugs the new code is silently sidestepping, that's information — surface it, don't auto-recommend reuse.

This step catches the failure mode where the skill "discovers" a function that was renamed, deleted, or never had the behavior the new code needs.

## Output

A single table sorted by priority. Use this exact shape:

| # | Priority | New code (file:line) | Decision | Existing impl (file:line) | Why |
|---|----------|----------------------|----------|---------------------------|-----|

- **Priority** = `P0` (clear duplication of a load-bearing helper / repo / matcher), `P1` (minor helper duplication or near-miss), `P2` (style / consistency suggestion).
- **Decision** = `Reuse` | `Extract` | `Keep duplicate (justified)`.
- **Why** = one sentence. For Reuse, cite the guarantee that the existing impl is equivalent. For Extract, name the call sites (≥3). For Keep, name the reason from the rubric above.

End with: `Total: N findings (P0=x, P1=y, P2=z). M new symbols reviewed.`

If everything in the diff is novel and no existing implementation overlaps, say so directly. Don't invent findings.

## Related

- `/qclean` — defensive-cruft cleanup (sister review).
- `/qsimplify` — simplification review (overlapping but broader).
- `/qbcheck` — validate a finding before acting on it. Run before extracting if you're not confident the call sites really converge.
- `/qcheck` — broader code review.
