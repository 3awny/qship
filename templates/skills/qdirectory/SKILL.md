---
name: qdirectory
description: Review where new files/modules were placed — do they sit in the right directory, follow the repo's layering and naming conventions, and avoid creating parallel structures. Use after adding files to confirm the change fits the existing architecture; qship runs it as Step 7.3.
---

# Directory Organization Review

You are a directory-organization specialist for the {{COMPANY_SLUG}} monorepo. The goal is to catch new files that landed in the wrong place — wrong layer, wrong domain, or in a "common/utils/shared" directory whose existing contents don't actually fit. Without this catch, parallel hierarchies grow and refactors become impossible.

## Scope

Default to **new and substantively-moved files in the diff**:

```bash
git diff develop...HEAD --diff-filter=AR --name-only
```

For each file, classify which repo it lives in (any in your repos.json) and which layer (`api/`, `services/`, `repositories/`, `data_models/`, `schemas/`, `migrations/alembic/`, `ui/`, `connectors/`, `tests/`). Whole-repo audits are an opt-in (`--full`) — too noisy as a default.

## Core principle: read the directory before placing into it

A directory's name tells you what someone *intended*. Its contents tell you what it *is*. They diverge over time. **Before suggesting that a new file go into an existing directory, list its contents and read 2–3 representative files.** The cohesive purpose you find determines whether the new file fits.

> **Example failure:** `{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/common/` looks generic, but its contents are all {{COMPANY_SLUG_UPPER}} {{PRIMARY_REPO_NAME}} API clients (`users.py`, `gadgets.py`, `gizmos.py`). Putting connector infrastructure there mixes two unrelated concerns. Correct location: `{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/connectors/common/` — following the `common/` pattern already used inside individual connectors but at the cross-connector level.

This is the most common failure mode of automated directory advice — recommending placement based on the directory's *name* rather than its *current contents*.

## {{COMPANY_SLUG}} layer map

Use this as the anchor when assessing placement. Every new file should map to exactly one cell:

| Layer | What lives there | What does NOT |
|---|---|---|
| `api/` (or `routers/`) | FastAPI route declarations, request/response handling, HTTP-specific validation | Business logic, SQL, domain rules |
| `services/` | Business logic, orchestration across multiple repos, side-effect coordination | Direct SQLAlchemy queries, HTTP serialization |
| `repositories/` | Data access — single-aggregate CRUD, queries, embedding side-effects | Cross-aggregate orchestration, HTTP types |
| `data_models/` (SQLAlchemy) | ORM model classes only | Pydantic schemas, business logic |
| `schemas/` (Pydantic) | Request / response shapes, validators | ORM models, DB queries |
| `migrations/alembic/versions/` | Alembic revisions | Anything else |
| `connectors/` | Third-party integrations (External ERP, external CRM/accounting connector, etc.) | {{COMPANY_SLUG_UPPER}}-internal API clients |
| `ui/components/react/` | React/TSX components | Page-level Dash layouts |
| `ui/pages/` | Dash page layouts and callbacks | React component definitions |
| `tests/` | Test files (`test_*.py`, `*.test.tsx`) | Production code |

When a new file straddles two layers (HTTP code + SQL in the same file, ORM + Pydantic mixed), that's a finding. Split it.

## Cross-repo placement rules

These come from your memory and recur in real PRs:

- **Domain separation** — domain-specific concepts (a domain's tables and services) belong in that domain's repo, NOT in the shared/primary repo (memory: `feedback_domain_separation`). Only cross-domain primitives (auth, organizations, files) live in the shared/primary repo.
- **Each repo's alembic manages only its own schema.** Migrations that touch another repo's schema belong in that repo's `alembic/` — flag any migration file that creates / alters tables outside its own repo's schema.
- **Single source of truth per table** — don't split reads/writes for the same data across your repos (memory: `feedback_source_of_truth_single_table`).
- **Cross-schema FKs are fragile** — prefer plain UUID columns over `ForeignKey('public.x.id')` from a {{PRIMARY_REPO_NAME}} table (memory: `feedback_cross_schema_fk_fragile`).
- **Repo owns persistence** — a service in repo A can't write directly to repo B's tables; it goes through B's API (memory: `feedback_repo_owns_persistence`).
- **No denormalized multi-scope columns** — when a relationship is per-tenant or per-catalog, use a bridge table, not a denormalized JSON/array column (memory: `feedback_no_denormalized_multi_scope_columns`).

A new file that violates any of these is at minimum a `P1` finding.

## Patterns to look for

For each new file in the diff, ask:

1. **Does this file's name hint at a different layer than the directory it's in?** (e.g., `*_repository.py` inside `services/`).
2. **Does this file's content match the layer's contract?** (FastAPI route in `services/` is misplaced.)
3. **If it's in a `common/` / `shared/` / `utils/` directory, do the existing files there share its concern?** (See the core principle above.)
4. **Is this a new directory?** A new directory should have a clear cohesive purpose stated in a `__init__.py` docstring or a sibling README. New empty / mixed directories rot.
5. **Does this file duplicate the parallel hierarchy of an existing area?** New `services/foo/` when an existing `services/foo_legacy/` is being phased out — flag it; don't compound the duplication.

## Keep as-is — when moving is wrong

Don't push every misnamed file toward refactoring. Leave it alone when:

- Moving would break a chain of imports across multiple repos (cite the chain).
- The "wrong" directory is the explicit convention and your suggested correct one isn't actually used yet.
- The file is a deliberate one-off (e.g., a migration script, a one-shot data fix) where placement won't compound.
- The diff is small and the misplacement predates the change — out of scope.

If the verdict is keep-as-is, name the reason explicitly. Silent acceptance of misplaced files is the failure mode.

## Verify before reporting

For every "move X to Y" finding:

1. Confirm Y exists by listing it. If Y doesn't exist, the recommendation is "create Y" — different finding, different cost.
2. Read 2–3 files in Y to confirm the cohesive purpose still matches the new file's purpose.
3. Trace imports — moving the file means updating import paths in callers. Quantify how many files change so the user can scope the work.

## Output

Single table sorted by priority:

| # | Priority | File (current path) | Issue | Recommendation | Existing target (file:line / dir) | Importers affected |
|---|----------|---------------------|-------|----------------|------------------------------------|--------------------|

- **Priority** = `P0` (cross-repo / cross-schema violation that creates a real bug — orphan migration, cross-schema FK, a migration touching another repo's schema), `P1` (wrong layer, parallel hierarchy, miscategorized into `common/`), `P2` (naming / minor consistency).
- **Recommendation** = `Move to <path>` | `Split into <A> + <B>` | `Create new directory <path>` | `Keep (reason)`.
- **Importers affected** = approximate count from `rg "from <old.path>"`. Helps the user gauge cost.

End with: `Total: N findings (P0=x, P1=y, P2=z) across M new files. Estimated import updates: K.`

If the new files all land cleanly, say so directly.

## Related

- `/qreuse` — should this code be a new file at all, or extend an existing one? (sister skill.)
- `/qcheck` — broader code review.
- `/qbcheck` — validate a finding before acting on it. Especially useful here because moves are expensive — false positives waste a lot of import-rewriting.
- `/qmigrationdevcheck` — run after any alembic relocation to confirm the chain is still valid.
