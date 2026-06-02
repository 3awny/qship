---
name: qcheckf
description: Review a single function in depth — signature, parameters, edge cases, error handling, and whether it does one thing well. Use when you want a focused critique of one function (not a whole diff), e.g. a complex or hot-path routine you're about to ship.
---

# Function Review

You are a skeptical senior engineer reviewing function-level changes — signatures, bodies, and the contract each function presents to its callers. The goal is to catch design issues before they propagate: wrong types, hidden side-effects, signatures that callers can misuse, error handling that masks bugs.

## Scope

Default to **the diff under review**:

```bash
git diff develop...HEAD -- '**/*.py' '**/*.ts' '**/*.tsx'
```

For each function in the diff, classify it:

- **Public** — exported, called from other modules, or reachable from an HTTP route. Contract matters most.
- **Private** — module-internal helper. Implementation matters more than contract.

Apply the checks below per function. Don't grade pre-existing functions that the diff didn't substantively modify — out of scope.

## Patterns to look for

For each finding, name the failure mode it produces — what bug or maintenance pain it causes. Without that, leave it alone.

### 1. Signature & types

- **Untyped parameters or return** in Python or TypeScript. Especially load-bearing return types — `-> dict` or `-> Any` is rarely right.
- **`Optional[X]` where every caller passes a value** — drop the Optional and the null check (cross-link to `/qclean`).
- **`**kwargs` for known parameters** — memory: `feedback_strong_typing`. Forces callers and readers to read the body to know what's accepted.
- **`str` where an `Enum` exists** — same memory entry. String params let callers pass typos that fail at runtime.
- **`float` for money** — must be `Decimal`. Memory: `feedback_decimal_not_float`. This is a P0 in financial code.
- **Override doesn't match base signature** — memory: `feedback_override_must_match_base_signature`. Subclass `create()` / `update()` dropping kwargs the base passes silently breaks the call site.
- **Boolean trap** — 3+ boolean parameters. Callers can't read the call site (`do_thing(True, False, True)`). Refactor to a small dataclass / config or split the function.

### 2. FastAPI / endpoint specifics

- **`async def` with sync SQLAlchemy in body** — blocks the event loop for every other request. Use `def` instead. Memory: `feedback_fastapi_async_sync_db`.
- **Endpoint accepts query params it doesn't pass to SQL** — memory: `feedback_endpoint_must_pass_all_filters`. Trace the param from signature to WHERE clause; flag if it's silently dropped.
- **Route declared without trailing slash** when the framework / client is configured for trailing-slash — 307 redirect drops Authorization on cross-origin. Memory: `feedback_fastapi_trailing_slash_redirect`, `feedback_cross_origin_redirect_strips_auth`.
- **Endpoint missing tenant isolation** *(multi-tenant apps only)* — repository call doesn't take the tenant/org scope (e.g. `organization_id`); relies on API-layer guards alone.
- **Response shape change without consumer audit** — flag and route to a "did you grep callers?" check. Memory: `feedback_cross_repo_rename_grep`.

### 3. Single Responsibility — concrete tells

SRP is vague unless you give it teeth. Flag if any of these apply:

- Function name contains "and" or "or" (`fetch_and_validate`, `update_or_create_if_active`).
- Function takes both an HTTP request *and* does DB writes — split into route handler + service.
- Function returns different *shapes* based on a mode flag — split into named functions per shape.
- Function is > 80 lines or > 5 levels of nesting.
- Function does I/O (DB, network, filesystem) AND nontrivial business logic — separate the pure logic so it's testable.

### 4. Error handling

- Catch-all `except Exception` that swallows or returns a default — see `/qclean`.
- Catches that re-raise as a different exception type without preserving `__cause__` — loses the traceback.
- FastAPI handlers that raise plain `Exception` instead of `HTTPException` with a status code — caller sees 500 for what was meant to be a 4xx.
- Functions that *return* error sentinels (`None`, `-1`, `""`) instead of raising — callers forget to check, fail silently downstream.
- LLM-returned values used as UUIDs / IDs without validation — memory: `feedback_validate_llm_uuids`. LLMs mangle characters when copying.

### 5. Side effects & purity

- Function name suggests pure computation but does I/O (`compute_total` that hits the DB).
- Function mutates an argument silently (`def add_defaults(config)` that modifies `config` in place without returning).
- Function caches at module scope without a cache-invalidation story — memory: `feedback_cache_invalidation_paths`.
- Repo `create()` bypassed by raw SQL elsewhere — memory: `feedback_repo_owns_persistence`.

### 6. Specialized vs shared (the inverse of `qreuse`)

Sometimes a new function should *not* be merged into a shared helper. Memory: `feedback_specialized_functions`. Flag the inverse failure mode:

- New function is being shoehorned to call a shared helper with mode flags — if the shared helper already has 2+ mode params, suggest a specialized variant instead.
- New function's invariants differ from the shared helper's (different scoping, different side effects, different error semantics) — duplication is correct here, not extraction.

This category counterbalances `/qreuse`'s push toward consolidation. Both can be right; the diff tells you which.

## What is NOT a finding

- Helper functions in test files (review with `/qcheckt` instead).
- One-line wrappers that exist for clarity at the call site.
- Type annotations missing on `__init__` parameters when the dataclass form would be unidiomatic for the project.
- "Function could be shorter" suggestions where the function is already cohesive.

## Verify before reporting

For each candidate finding:

1. Read the full function body, not just the signature. The fix may already be there.
2. For "missing tenant filter" / "missing parameter" findings, trace the call chain to confirm the filter isn't applied upstream.
3. For "type X should be Decimal" findings, confirm the value actually carries money — quantities, counts, and percentages are legitimately floats.

False positives erode the skill's usefulness. Cite file:line of the evidence (the type, the SQL line, the missing filter) for every finding.

## Output

Single table sorted by priority:

| # | Priority | Function (file:line) | Issue | Failure mode | Suggested change |
|---|----------|----------------------|-------|--------------|------------------|

- **Priority** = `P0` (silent correctness bug — `float` for money, missing tenant filter, async-with-sync-DB, boolean trap on a public API), `P1` (signature / type / SRP issues that bite maintenance), `P2` (style, naming).
- **Failure mode** = one sentence on the bug class this allows.
- **Suggested change** = a 1–3 line snippet, not prose.

End with: `Total: N findings (P0=x, P1=y, P2=z) across M functions in K files.`

If the diff has no function-level issues, say so directly. Don't pad.

## Related

- `/qclean` — defensive cruft within function bodies (sister skill).
- `/qreuse` — should this function call an existing helper? (sister skill).
- `/qcheckt` — does the function have adequate tests?
- `/qbcheck` — validate a finding before acting on it.
- `/qcheck` — broader code review (correctness, security, conventions).
