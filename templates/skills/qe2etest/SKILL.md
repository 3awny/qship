---
name: qe2etest
description: Run quick end-to-end smoke testing for {{COMPANY_SLUG_UPPER}} changes by tracing changed code paths through the real local stack and verifying behavior live.
---

# End-to-End Test of the Current Change

Run a full end-to-end test of whatever was implemented in this conversation. The goal is **a comprehensive scenario matrix that leaves nothing questionable** — exercise every layer the change touched, prove the change works through real (not mocked) interfaces, and surface anything that doesn't.

> **Scope:** This drives the change against your **primary service** (started by `/qspinuplocal`). If your change spans multiple services, start the others yourself and add their triggers to the scenario matrix — `/qspinuplocal` is single-service by design.

## Companion skills

- **`/qspinuplocal`** owns the local stack lifecycle for your primary service (against a local DB). This skill **always** calls `/qspinuplocal` for spin-up — it handles `.env` overrides, the `load_dotenv(override=True)` footgun, port collisions, and worktree resolution.
- **`/qmanualt`** owns the UI E2E flow (Playwright + Claude in Chrome). For any UI change, hand control to `/qmanualt` after the API/worker layer is verified — see "UI testing — delegate to /qmanualt" below.

This skill (`/qe2etest`) is the orchestrator: it audits the diff, **traces every changed code path forward to its production trigger** (HTTP endpoint, worker queue, cron, scheduled job), drives those triggers itself against the real stack, delegates UI to `/qmanualt`, and verifies in the DB. It runs `/qspinuplocal` to start the stack.

## The cardinal rule

**An E2E pass requires invoking the same entrypoint production uses.** A unit test, a Python REPL call into the changed function, or "the migration applied cleanly" is NOT an E2E pass — it's a partial check. If the change is reachable from a worker, the worker MUST be the thing that fires the code path. If the change is reachable from an HTTP route, `curl` MUST be the thing that fires it. Always. No exceptions, no shortcuts to "save time."

The single most common failure mode of this skill is the agent verifying a code change at the wrong altitude — proving the function works in isolation while never demonstrating the production trigger reaches it. Section "Step 1.5" below exists to prevent exactly that.

## Hard rules — non-negotiable

- **Production trigger or it didn't happen.** Every changed code path MUST be fired by the same entrypoint production uses. Worker code → run the worker script. HTTP code → `curl`. Cron code → invoke the cron entry. If you can't fire the production trigger, the result is **BLOCKED**, not "passed via alternative verification."
- **/qspinuplocal is unconditional** for any change touching API / Service / Repository / Worker / UI / Cross-repo. The only exemption is a change purely in `alembic/versions/*` with no runtime impact. Don't second-guess: call the skill first, then test.
- `DEV_MODE=true` is the default for local stack runs. The `DEV_MODE=false` purity goal is a CI / staging concern. Locally, the external auth provider, Dash routes, Auth-gated wizard flows, and many internal endpoints don't have a non-DEV-MODE path that works without a real user session. Use `DEV_MODE=true` unless you have a specific reason to test the auth boundary itself.
- **DEV_MODE is env-var only — NEVER commit auth/middleware code changes.** If you find yourself thinking about editing `oauth_provider_auth.py`, middleware, or any auth code on the feature branch to make a test pass, stop. That's a code change leaking into the testing surface; revert before commit. Precedent: `feedback_devmode_badge_deadlock.md`.
- Local database only: `local_demo_db` (the canonical default) or whatever DB `/qspinuplocal` was invoked against. **Never write to a staging or production DB.** Read-only queries against staging are fine if the user explicitly provides them and the URL points at a DB provider branch — otherwise stay local.
- Worktrees take priority. If the user mentioned worktree paths in this session, the spin-up MUST point at those worktrees (pass them to `/qspinuplocal`). Otherwise the test exercises develop, not the change.
- Real interfaces over mocks. UI clicks via the Chrome extension, API calls via `curl`, worker runs via the actual processor scripts, DB checks via `psql`. If the runtime can't be brought up, **mark BLOCKED** — don't substitute a unit-test for the e2e check.
- Hard fail on missing layers. If the change touched the worker but the worker can't be started, that's a finding. Surface it; don't quietly skip.

## Step 0.5 — Re-read tickets + ACs (input enrichment)

Before auditing the conversation, pull in the **spec source-of-truth** so the scenario matrix is grounded in stated acceptance criteria, not just the implementation diff. This is what differentiates a comprehensive E2E from a check-what-I-just-wrote review.

For each ticket referenced in the session (Jira ID in commit messages, branch name, or chat):

1. Fetch the ticket via the atlassian MCP (`mcp__atlassian__jira_get_issue`) or by extracting the ID from `git log` and reading it. Capture: summary, description, **every acceptance criterion (AC) verbatim**, attached design notes / TRD links.
2. If the ticket links to a Confluence TRD or design doc, fetch that too (`mcp__atlassian__confluence_get_page`). Read the §3 / §4 / §AC blocks.
3. If the branch contains multiple commits closing multiple tickets, collect ACs across ALL of them.

Save the union of ACs to a working note so the brainstorm step can read them as input:

```
Acceptance criteria source-of-truth:
- {{JIRA_PROJECT_KEY}}-XXX (summary): AC1, AC2, AC3, ...
- {{JIRA_PROJECT_KEY}}-YYY (summary): AC1, ...
- TRD §3.2 invariants: ...
```

Skip this step only when the change has no Jira backing (true ad-hoc work). For epic-scale work or wave-of-tickets sessions, this step is non-negotiable — the matrix without ACs is the matrix of what the implementer remembers being asked to do, which is always a subset of what they were actually asked.

## Step 1 — Audit the conversation

Re-read what was implemented in this session. Build a checklist of *what changed* and which runtime layers it touches.

| Layer | What it covers | How to detect from the diff |
|---|---|---|
| **DB / migrations** | Alembic migrations, ORM-model changes, new indexes, listeners | New file in `alembic/versions/`, edits under `data_models/orm/`, new SQLAlchemy event listeners |
| **API** | FastAPI routers, request/response schemas | Edits under `api/v1/*.py` or `api/routes.py`; new endpoints in `*_router` |
| **Service / Repository** | Pure backend logic | Edits under `services/` or `repositories/` not exposed via HTTP |
| **Worker** | job-queue consumers, claim loops, scheduled jobs, **OR any service/repo function reachable from a worker** | Edits under your worker entrypoint(s) (`services/*worker*.py`, `scripts/*-worker.py`), OR a function whose call graph reaches one (`grep` the changed symbol there) |
| **UI** | React under `{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react/src/` | Edits under that path, new endpoints called by `fetchJson`, new modals / state |
| **Cross-repo contract** | any boundary between two of your repos | Same symbol/string referenced in two repos in the same change set |

**Layer ambiguity → assume the wider scope.** A change to a service function used by both an HTTP route and a worker is BOTH an API change AND a Worker change. Test both triggers.

Print the audit so the user sees what you're about to test:

```
Layers touched: DB (X), API (Y), Service (Z), Worker (W), UI (U)
Test plan:
  - DB:       <one line per scenario>
  - API:      <one line per scenario>
  - ...
```

## Step 1.5 — Trace the production trigger (MANDATORY)

For every changed symbol identified in Step 1, walk forward through the call graph until you reach a production entrypoint: an HTTP route, a worker claim loop, a cron entry, or a UI click handler. Until you can name the trigger, **you do not know how to run the E2E test**.

For each changed file/function, fill in:

```
Changed: <file>:<symbol>
  ↑ called by: <function/method>
  ↑ called by: <controller/worker entry>
  ↑ production trigger: <HTTP path | worker script | cron job | UI button>
  ↑ claim predicate: <e.g. "WHERE status='Ready' AND status_id IS NULL">
```

If multiple production triggers reach the changed code, list ALL of them. **Each one is a separate test scenario.**

If you can't construct the call chain in five minutes of grep / Read, **stop and ask the user** which trigger they want exercised — don't guess and end up running the wrong test.

### Example — what this prevents

Changed `record_classification/service.py:_engine_record_adapter` (drops tax_rate before policy engine).

Without this step, the agent verifies via a unit test that the adapter now forwards tax_rate, declares pass, and ships. The user has to come back later and say "actually reprocess the record through the worker." That's a failure of this skill.

With this step:

```
Changed: record_classification/service.py:_engine_record_adapter
  ↑ called by: RecordClassificationService.classify_items
  ↑ called by: scripts/classify_worker.py (the WORKER)
  ↑ production trigger: classify_worker.py polling loop
  ↑ claim predicate: public.record.status='Ready' AND no classification rows exist
```

Now the test plan writes itself: spin up the stack, reset a record to `Ready` with classifications cleared, run `python scripts/classify_worker.py --once`, verify the resulting classification rows.

### How to find the claim predicate

For worker code, grep for `SELECT` against the entity table in the worker script. Example:

```bash
grep -n "SELECT\|WHERE\|FROM {{PRIMARY_REPO_NAME}}\|FROM {{PRIMARY_REPO_NAME}}" scripts/classify_worker.py
```

The first significant `WHERE` clause is the claim predicate. Copy it verbatim into the audit. The reset SQL in Step 4 (Worker testing) is just the inverse of that predicate applied to your test entity.

## Step 2 — Spin up the local stack (call /qspinuplocal)

**Always call `/qspinuplocal`.** Don't hand-roll uvicorn / serve.py / processor commands — that path repeatedly hits the same pitfalls ({{PRIMARY_REPO_NAME}} `load_dotenv(override=True)` clobbering env vars, stale `{{ENV_SERVICE_URL_KEY}}=:9000` in older `.env` files, port 8000 occupied by Docker, missing `DEV_TENANT_ID`). The skill handles all of these; reimplementing them in this step burns time and ships subtle bugs.

The call:

```
/qspinuplocal --db-name <db> [--tenant-uuid <uuid>] [--worker] --worktree-core <path> --worktree-app <path>
```

Pass through what the user gave you in this session:

- **Worktree paths — REQUIRED in qship context.** Pass BOTH `--worktree-core` and `--worktree-app` whenever the change lives in a worktree (i.e. always, under `/qship`). `/qspinuplocal` Step 4.5 mutates `.env` and Step 0.5 now hard-refuses to run against the maintree without an explicit `--allow-maintree` opt-in — you must NOT pass `--allow-maintree` from qe2etest. Locating the worktrees:
  - If `pwd` is under `{{STATE_ROOT}}/worktrees/<TICKET>/`, derive `--worktree-core $TICKET_DIR/{{PRIMARY_REPO_NAME}}` and `--worktree-app $TICKET_DIR/{{PRIMARY_REPO_NAME}}`.
  - Otherwise scan `git -C {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}} worktree list` and `... {{PRIMARY_REPO_NAME}} worktree list` for the branch the user is working on and pass those paths.
  - If only ONE worktree exists (e.g. {{PRIMARY_REPO_NAME}} only) and the other repo is unchanged in this ticket, you may pass `--no-core` or `--no-app` to skip the unaffected side — but never substitute the maintree path for the missing worktree.
- **Worker** — if Step 1 marked the Worker layer in scope (including the wider sense from the call-graph trace in Step 1.5), pass `--worker`. The polling worker is then live and will pick up reset entities automatically.
- **DB name** — usually `local_demo_db` (the canonical default). Use whatever the user told you to use; don't default to `{{LOCAL_DEV_DB_NAME}}` when they named a specific DB.

**Maintree-protection contract (non-negotiable):** the user's day-job runs against the maintree at `{{CODEBASE_ROOT}}/{{COMPANY_SLUG}}-*`. This skill MUST NOT mutate the maintree `.env` files — they carry the user's working tenant / DB / `{{ENV_SERVICE_URL_KEY}}` config and a rewrite would silently break their next IDE run. Verify by reading the `.env` file path printed in `/qspinuplocal` Step 4.5 output: it must start with `{{STATE_ROOT}}/worktrees/` (or whatever explicit `--worktree-app` path you passed), NOT `{{CODEBASE_ROOT}}/`. If `/qspinuplocal` aborted with the "refusing to use maintree" guard, fix your invocation — do NOT bypass the guard with `--allow-maintree`.

### Port detection + fallback (read this BEFORE any curl / Playwright call)

`/qspinuplocal` Step 1 picks ports deterministically: it tries the canonical port first (e.g. 8000), kills its OWN stale process if it finds one, and walks a fallback ladder (18000/18001/…) when a port is held by something else (the user's maintree IDE run, Docker, another tenant's stack, a sibling qship run). It writes the chosen ports to `/tmp/{{COMPANY_SLUG}}-ports.env` and prints them in the Step 9 report. The fallback is what lets a qship / qe2etest run coexist with the user's day-job stack on the canonical ports.

**Source the port file at the top of this skill's session AND re-source it after every restart**, because the fallback may have shifted between runs:

```bash
set -a; . /tmp/{{COMPANY_SLUG}}-ports.env; set +a
# now ${{ENV_SERVICE_URL_KEY}} / ${{ENV_SERVICE_URL_KEY}} / $SERVICE_HEALTH / $SERVICE_HEALTH
# point at whatever the running stack actually bound to.
```

**Hard rule for this skill: NEVER hardcode `:8000` / `:8001` / `http://localhost:8000` / `http://localhost:8001` in any curl command, Playwright base URL, evaluate_script call, or DOM-assertion fragment.** Use the env vars. If a hardcoded literal lands in `phase3-evidence.md`, the qship enforcement hook treats the evidence as suspect.

After spin-up, verify with `curl "${SERVICE_HEALTH}"`. If it fails, dump `/tmp/{{COMPANY_SLUG}}-service.log` to the user and STOP. Don't proceed with a half-up service. If the chosen port differs from the default, mention that in the test-run preamble of `phase3-evidence.md`.

If `/qspinuplocal` is genuinely unavailable in this environment, document the gap to the user and ask to install it — DON'T hand-roll the commands. The hand-rolled path is a known time sink.

## Step 3 — Build the scenario matrix (via brainstorming, two-pass)

Don't hand-write the matrix from memory. Use the **`superpowers:brainstorming` skill** to design a comprehensive + robust matrix in two passes — one grounded in the ACs from Step 0.5, one independent from the implementation. Union the two.

### 3a — AC-grounded pass

Invoke brainstorming with the AC source-of-truth as the input. For each AC, generate the **5 canonical scenario classes**:

| Class | What it asks |
|---|---|
| **happy_path** | the AC's stated outcome works for the obvious input |
| **negative** | the AC's stated outcome FAILS correctly for invalid input |
| **boundary** | edge values (empty, max, null, single-element, off-by-one) |
| **edge** | atypical-but-valid input the AC implicitly accepts (Unicode, leading-whitespace, concurrent caller, partial-state) |
| **auth** | the AC's behaviour at the auth boundary (no token, role-gated, or — if the app is multi-tenant — wrong tenant) |

Output: matrix-1 with 5 × N rows where N = number of ACs.

### 3b — Implementation-independent pass

Invoke brainstorming a SECOND time, this time with the **implementation diff** as the input and the AC list HIDDEN. Ask: "what could break in this code path that the spec didn't think to require?" This catches the gaps between what was asked and what was built.

Specifically have the brainstormer enumerate:

- **Idempotency** — same write twice. Same job claim twice. Same row insert with conflict.
- **Concurrency / dedup** — two simultaneous triggers, two clicks on Run, two webhooks for the same event.
- **Async propagation** — write triggers worker, worker actually runs and downstream state catches up. Heartbeats, retries, dead-letter queues.
- **Cross-wave / cross-repo interactions** — if this change is part of a multi-wave epic, scenarios that exercise THIS change × adjacent waves' changes together (a write under the new RLS policy reading via the new schema field, etc.).
- **Migration rollback / replay** — if alembic touched, the down() path runs cleanly AND data is recoverable.
- **Failure mode adversarial** — for every guarantee the implementation claims, design a scenario that would expose its violation (deadlock, partial commit, racing writers, lost update).
- **Observability** — log lines / metrics / traces emit at expected verbosity. Errors are diagnostic (not "an error occurred").

Output: matrix-2.

### 3c — Union + score

Merge the two matrices, dedupe overlapping scenarios, **score each** on:

- **AC coverage**: which AC does this scenario prove (or "implementation-only" if pass-2 only)?
- **Production-trigger fidelity**: is the scenario fired through the production entrypoint (Step 1.5), or is it an integration shortcut? (Latter is OK but flag it.)
- **DB requirement** (per the table below).

Final matrix: 5 columns minimum — `ID | Type (AC-grounded / impl-only / cross-wave / adversarial) | AC ref | Method (pytest / curl / psql / playwright / worker) | Concrete invocation | DB chosen`.

Target size: 25-50 scenarios for a single-ticket change, 50-100 for an epic-wave-merged change. Smaller is fine if the change surface is tiny — but justify low count in the report rather than skipping.

Print the matrix before you run it. Save it as `/tmp/qe2etest-matrix-<branch-or-ticket>.md` so the report can reference it.

### Per-scenario database selection (mandatory)

Different local Postgres DBs carry different data shapes. Pick the most-data-rich DB for each scenario, not a single default. The mapping below is the canonical default for the {{COMPANY_SLUG}} monorepo — overrideable per scenario if its needs cite a specific DB.

| Scenario category | Default DB | Why |
|---|---|---|
| Validation policy templates / instances, catalogs, taxonomies — the canonical default for most scenarios | `local_demo_db` | richest item/policy/tag data locally — default for validation-policy scenarios |
| Reference-document matching, record-to-reference reconciliation, reconciliation match, classification policies that touch reference documents | `local_alt_db` | densest matching corpus locally — best for matching algorithms, edge cases on quantity/price drift, multi-line record scenarios |
| (your-domain) entities, Sample Category catalogs, sample taxonomies specifically | `local_acme_corp_db` | (your domain)-tuned catalog/policy data; use only when a scenario explicitly needs (your-domain) shapes |
| Multi-tenant org-scoping / RLS / membership table behaviour across 3+ orgs | `{{LOCAL_DEV_DB_NAME}}` | multiple tenant orgs, canonical multi-tenant smoke-test DB |
| Schema-only / Pydantic / OpenAPI / pure-unit | any (prefer `local_demo_db` for parity with epic-level evidence) | no DB query needed |
| Migration alembic up/down / schema introspection / RLS policy SQL | `local_demo_db` (or whichever holds the most recent migrated state) | migrations operate on schema not data |
| Connector ingestion (external CRM/accounting connector, ERP, webhooks) — cross-tenant routing, deprecation logging | `{{LOCAL_DEV_DB_NAME}}` | multi-tenant routing requires multiple orgs |

**Procedure per scenario:**
(a) Identify which entity tables / behaviours the scenario queries.
(b) Pick the DB from the table above; if a scenario explicitly cites a DB in the matrix row, that wins.
(c) **Group scenarios by DB to amortize server-restart cost.** uvicorn holds a connection pool to one DB — switching DBs requires killing and respawning the server. Aim for ≤3 server restarts across the entire matrix. Order the matrix so all `local_demo_db` rows run together (this is the default and will usually be the largest group), then all `local_alt_db`, then any `local_acme_corp_db` or `{{LOCAL_DEV_DB_NAME}}` rows.
(d) Capture the chosen DB in the scenario's evidence row (column "DB used") so reviewers can reproduce.
(e) If a scenario requires a fixture that doesn't exist in ANY local DB, mark it SKIP with rationale citing the missing data, AND drop a note to `/tmp/qe2etest-db-fixture-gap-<ts>.md` for a follow-up seed task. Don't spin up an empty fresh DB just for one scenario — local seed data is the point.

If unsure, default to `local_demo_db`. The clean re-clone command is:
```bash
/qlocalclonedb --tenant "Demo Tenant" --db-name local_demo_db --reclone
```

## Step 4 — Run the scenarios

### DB switching between scenario groups

The matrix from Step 3 is sorted by DB. Between groups, you MUST kill + respawn the stack so uvicorn binds to the new DB. The {{PRIMARY_REPO_NAME}} `load_dotenv(override=True)` caveat means setting env vars at command line is insufficient — `/qspinuplocal` rewrites the `.env` files. Use:

```bash
# Switch from current DB to <new_db>:
pkill -f "serve.py" 2>/dev/null
pkill -f "uvicorn.*{{COMPANY_SLUG}}\." 2>/dev/null
sleep 2
/qspinuplocal --db-name <new_db> [--tenant-uuid <uuid>] [--worker] [--worktree-app <path>]
```

Verify the swap actually happened before running scenarios:
```bash
ps -ax -o pid,command | grep "start_server\|uvicorn" | grep -v grep
psql -h localhost -U {{LOCAL_DB_USER}} -d <new_db> -c "SELECT current_database();"
```

Capture the DB swap as an evidence row in the matrix: `S<id> | (db-switch) | local_alt_db → local_demo_db | server-restart succeeded`.

### API testing

Use `curl` against the local stack. Always:

- Capture the HTTP status, response body, and (if the call writes) follow-up `psql` queries to confirm DB state.
- Diff DB state before vs after where it matters (count, sum, specific row).
- If auth is required, walk through the real auth flow (the external auth provider dev login) — never substitute the bypass.

```bash
# Example shape (use sourced ${{ENV_SERVICE_URL_KEY}} — never hardcode :8001)
curl -s -X POST "${{{ENV_SERVICE_URL_KEY}}}/api/v1/.../endpoint" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{...}' | jq
psql 'postgresql://{{LOCAL_DB_USER}}@localhost:5432/local_acme_corp_db' -c \
  "SELECT count(*) FROM public.<table> WHERE <predicate>;"
```

### Worker testing — REQUIRED if Step 1.5 traced any change to a worker entrypoint

The trigger is NOT "did this change introduce a new job category" — the trigger is "does the production call graph for this change include `scripts/*-worker.py` or any worker claim loop." If yes, the worker MUST run. No exceptions.

The pattern is always the same four steps. Do them in order; don't skip the reset.

#### 1. Pick a representative entity

Use the example the user mentioned in the conversation (e.g. record EXAMPLE-001) when available — the user picked it because it surfaces the bug or feature. If they didn't name one, pick one that satisfies the claim predicate AFTER your reset and exhibits the specific data condition the change targets (e.g. for the tax_rate fix: a record with a 0%-tax line and a category-specific policy applicable to its vendor).

#### 2. Reset the entity into the worker's claim shape

This is the step that's most often skipped, and skipping it makes the worker silently no-op (the entity is already past the claim predicate). Use the claim predicate you captured in Step 1.5 as a recipe for the reset:

```sql
-- Example for processor (claim: status='Ready' AND no classifications):
DELETE FROM public.record_classifications
 WHERE record_id = :doc_id;
UPDATE public.record
   SET status='Ready'
 WHERE record_id = :doc_id;
```

If the entity has dependent rows the worker writes to (`step_log`, `audit_trace`, `run_log`), wipe those too — otherwise the post-run verification confuses "old run output" with "this run's output."

**Snapshot the BEFORE state to the conversation** before running the worker. The user wants to see the broken state explicitly, not just the fixed state. One `SELECT` of the relevant rows is enough.

#### 3. Run the worker

Pick the right invocation:

| Worker | One-shot invocation |
|---|---|
| Record extraction | `python scripts/extract_worker.py --once --batch-size 1` |
| Classification | `python scripts/classify_worker.py --once` |
| Email monitor | `python scripts/worker_listener.py --once` |
| Anything else | grep the script for `--once` / equivalent flag |

Run from the **fix worktree**, not the canonical worktree — otherwise you're testing develop, not the change:

```bash
cd <fix-worktree-path>
DATABASE_URL=... GLOBAL_DATABASE_URL=... ENFORCE_DEV_DATABASE_URL=... \
DEV_MODE=true PYTHONPATH=<fix-worktree>:<{{PRIMARY_REPO_NAME}}> \
<{{PRIMARY_REPO_NAME}}-venv>/bin/python scripts/<worker>.py --once 2>&1 | tail -40
```

Capture the tail of stdout. If the worker reports `Processed: 0 | Failed: 0`, the claim predicate didn't match — go back to step 2 and fix the reset.

#### 4. Verify in the DB (the AFTER state)

Re-run the same `SELECT` from step 2's snapshot. The diff between BEFORE and AFTER is the proof. Be explicit in the report:

```
Pre-worker:  line 5 had only `fixed` department; category + tax_code missing
Post-worker: line 5 has policy_auto for department, category, tax_code (category rule fired)
```

If the change affects worker-emitted log tables, also check those — `step_log.processed_line_count` is much more diagnostic than counting classification rows.

Cover scenarios beyond the golden path when relevant: claim → success, dedup when multiple jobs for the same key are queued, retry-on-transient-error, file-less vs file-backed shapes. But the golden-path "reset → run → verify" is non-negotiable.

### UI testing — delegate to /qmanualt

For any UI change, hand control to the **/qmanualt** skill. It owns the Playwright + Claude Chrome extension flow. Brief it with:

- What the change is (recapping from the audit).
- Which page(s) the change is visible on.
- The exact scenarios to walk (golden path + edge cases derived from Step 3).
- The DB-side assertions it should run after each click via `psql` / a worker tick.

`/qmanualt` will:

- Open the page in Chrome via the extension.
- Drive the click sequence.
- Capture screenshots of each meaningful state.
- Read DOM + console for assertions.
- Surface anything that doesn't render / behave correctly.

Do **not** try to drive the UI with raw `mcp__Claude_in_Chrome__*` tool calls in this command — that's what /qmanualt is for. Re-driving it here would duplicate logic that already lives in the skill.

### UI Testing Anti-Mock Contract — UUID resolution

**When the diff renders a UUID-typed field via any `resolve*Name` / `resolve*Value` hook, the Playwright run MUST hit the LIVE lookup endpoint, not a mocked hook.**

This rule exists because the {{COMPANY_SLUG}} React UI handles lookup-pending rendering via a specific canonical pattern — and mocked-hook tests cannot prove that pattern is applied correctly because mocks return synchronously (no loading window). Mocks guarantee the lookup never fails in test → silently mask any production environment where it would.

**Canonical pattern (the only acceptable shape — DO NOT reinvent):**

The {{COMPANY_SLUG}} React UI gates UUID→name resolution on `resolver.ready` and renders a Mantine `<Skeleton>` while the lookup fetch is in flight. Two canonical reference implementations to grep against:

1. `{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react/src/components/FeatureArea/ResolvedRefCell.jsx`:
   ```jsx
   if (loading) {
     return <Skeleton height={16} width={160} radius="sm" />;
   }
   ```

2. `{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react/src/components/FeatureArea/ResolvedSummaryView.jsx:94-121`:
   ```jsx
   const readyForKey = (k) => {
     switch (k) {
       case "entity_id":
       case "entity_ids":
         return resolveEntityName.ready;
       case "node_ids":
         return resolveRefName.ready;
       // …
     }
   };
   …
   {readyForKey(k) ? (
     <Badge>{renderScopeValue(k, scope[k])}</Badge>
   ) : (
     <Skeleton height={20} width={180} radius="sm" />
   )}
   ```

The `resolve*` hook family in `src/components/shared/{entity,node,organization,attribute,entityLookup}.js` exposes a `.ready` attribute on the returned function (see `entityLookup.js:121` — `resolve.ready = state.ready`). **Any new UI surface rendering a UUID-typed field MUST follow this `<Skeleton>` + `.ready` pattern. Truncated-UUID placeholders (`Entity 00000000…`) are NOT the codebase convention — flag them as a finding, do not introduce them.**

When `.ready === true && resolver(id) === null` (lookup loaded but the specific id genuinely isn't cached), the convention is to render the raw UUID. That's intentional and consistent across the file — but only acceptable *after* the Skeleton gate has been in place for the loading window.

**Detection — flag a UI change as "lookup-dependent" if its diff includes:**

- Any `resolveEntityName`, `resolveRefName`, `resolveOwnerName`, `resolveAttributeValue`, `resolveAttributeName`, `resolveGroupName`, or any other `resolve*Name` / `resolve*Value` call site.
- Direct rendering of a column whose value matches the UUID regex `\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`.
- `renderResolvedValue`, `renderRuleValue`, or similar wrapper.

Quick detection command for the worker to run against its diff:

```bash
git diff <BASE>..HEAD -- '*.jsx' '*.tsx' '*.js' '*.ts' \
    ':!**/dist/**' ':!**/build/**' ':!**/node_modules/**' \
    ':!**/*.min.js' ':!**/*.bundle.js' \
  | grep -E "resolve[A-Z][a-zA-Z]*Name|resolve[A-Z][a-zA-Z]*Value|renderResolvedValue|renderRuleValue"
```

If any line matches, this Anti-Mock Contract applies.

**For every lookup-dependent UI surface added in the diff, the Phase 3 test MUST:**

1. **Spin up your service via `/qspinuplocal`.** If your change depends on another service (the UI fetches an endpoint a sibling repo owns), start that one too — otherwise React fetches 404 → resolver returns `null` → UI either flashes UUIDs (no Skeleton gate) or renders Skeletons forever. After `/qspinuplocal` returns, `set -a; . /tmp/{{COMPANY_SLUG}}-ports.env; set +a` and verify with `curl -fs "${SERVICE_HEALTH}"` BEFORE running scenarios. The hook gate cares that the service(s) your change touches are reachable — not that they're on a canonical port.

2. **Drive Playwright (or Claude in Chrome) against either:**

   - **(a) The LIVE Dash UI at `${{{ENV_SERVICE_URL_KEY}}}/...`** — preferred. The Dash app already mounts the production React bundle with real hooks pointing at {{PRIMARY_REPO_NAME}} (`${{{ENV_SERVICE_URL_KEY}}}`); nothing to reconfigure. Source `/tmp/{{COMPANY_SLUG}}-ports.env` before invoking Playwright so `baseURL` reads `${{{ENV_SERVICE_URL_KEY}}}`.

   - **(b) The worktree e2e-harness with the lookup-hook MOCK ALIASES REMOVED** — i.e. webpack does NOT alias `shared/entityLookup` etc. to `mocks/*Lookup.js` files; the real hooks ship in the bundle and fetch at runtime from {{PRIMARY_REPO_NAME}}. For path (b), launch Chromium with `--disable-web-security` so the cross-origin fetch from the static harness server to {{PRIMARY_REPO_NAME}} doesn't get blocked by CORS preflight. Document the alias-removal + CORS-bypass in the evidence file.

   A mocked-hook harness run is NEVER an acceptable substitute for either path.

3. **Read the rendered DOM with `evaluate_script` and assert TWO things:**

   ```javascript
   const uuidRegex = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i;
   const root = document.querySelector('[data-rule-group-children-row]');
   const visibleText = root.innerText;

   // (i) NONE of the visible text matches the UUID regex
   const leaks = visibleText.match(new RegExp(uuidRegex.source, 'gi')) || [];
   expect(leaks).toEqual([]);

   // (ii) The expected resolved name DOES appear in the visible text
   expect(visibleText).toContain('Acme Corp Ltd');
   ```

   **Both assertions are required.** (i) alone catches leaks but misses the case where the resolver hangs forever and the UI shows only Skeletons (no UUID visible, but no name either). (ii) alone catches missing names but misses leaks. Together they prove resolution actually completed.

   For every UUID-bearing field, the test must capture (a) the raw UUID from the API/DB, (b) the expected resolved name from the lookup endpoint, (c) the rendered DOM text. The evidence file must record all three.

4. **Verify the codebase pattern is applied** — the new UI surface MUST gate its UUID-typed render on `resolver.ready` and show a Mantine `<Skeleton>` while not ready. Reference the canonical examples above. Truncated-UUID placeholders (`Entity 00000000…`) are NOT the convention — flag them as a finding. This is a code-shape check in addition to the runtime DOM assertion: grep the new surface for `Skeleton` or `\.ready\b` in proximity to the `resolve*` call.

5. **If {{PRIMARY_REPO_NAME}} cannot be brought up, the test result is BLOCKED — not PASS.** Write the BLOCKED rationale to the evidence file. A mock-backed-only run does NOT close the gap.

**Bug-fix mandate:** if a UUID leak is observed (rendered DOM contains a raw UUID where `.ready === false` should have shown a Skeleton):

- **DO NOT** introduce a truncated-UUID fallback (`Entity 00000000…` / `formatTruncatedUuid(...)`). That's not the codebase convention.
- **DO** apply the `<Skeleton>` + `.ready` gate per `ResolvedRefCell.jsx` and `ResolvedSummaryView.jsx`. Cite those files in the fix commit so future readers see the canonical reference.
- If `resolver.ready === true` but an entity genuinely isn't in the cache (resolver returns `null` by design, e.g. soft-deleted entity), accept the raw UUID render as the codebase convention — but only after the Skeleton gate is in place for the loading window.

**Matrix tagging:** for every UI scenario, tag the "DB" column with one of:

- `Live UI (demo)` — drove the real Dash UI against the named DB, with real lookup hooks → real {{PRIMARY_REPO_NAME}}.
- `Harness (real hooks + CORS-bypass)` — drove the worktree e2e-harness with mock aliases REMOVED, Chromium `--disable-web-security` set, {{PRIMARY_REPO_NAME}} live.
- `Harness (mocked hooks)` — mocked-hook harness only. This tag is ONLY acceptable for UI scenarios that DO NOT render any UUID-typed field. If the scenario touches lookup-dependent rendering, this tag means BLOCKED, not PASS.

Only the first two prove resolution; the third cannot.

### Cross-repo contract checks

If the change crossed repos (e.g. {{PRIMARY_REPO_NAME}} publishes a string that {{PRIMARY_REPO_NAME}} consumes), grep the *consumer* repo for the old literal in addition to running the e2e — broken contracts are easier to catch with a static check than at runtime.

## Step 5 — Verify in the database

For every write the test triggered, end with a `psql` SELECT that proves the expected row exists / is missing / has the right state. Don't assume the API response is the source of truth — it isn't. The DB is.

Specifically check, when applicable:

- `public.record_mappings`: the `is_active=true` rows are what the matcher will use.
- `task_queue`: `status`, `result_payload`, `attempts`, `last_failure` — and `job_metadata` for the input contract.
- `public.record_items.record_hash_id`: linkage from line → hash.
- Any audit / log table the change writes to.

## Step 6 — Report

Give the user:

1. **Scenario matrix with results.** Table: layer | scenario | result | evidence (file:line, db query, screenshot path). Pass/fail per row.
2. **What broke and why** — for any failure, a short root-cause hypothesis with the relevant log/grep.
3. **Coverage gaps** — anything in the audit you didn't get to and why.
4. **Whether the change is safe to ship** — explicit verdict: ✅ ready / ⚠ ready with caveats / ❌ blocked. Don't soften.

If everything passes, say so plainly. Don't pad with hedging. If something failed, lead with that, not with what passed.

### Self-check before declaring pass

Before writing the report, run this check against your own work in the conversation:

- [ ] **Step 0.5**: did you fetch every relevant Jira ticket's ACs (and any linked TRD §AC blocks) and save them as the brainstorm input?
- [ ] **Step 3a**: did you invoke `superpowers:brainstorming` with the ACs visible to generate matrix-1 (5 × N rows, one per AC × scenario class)?
- [ ] **Step 3b**: did you invoke `superpowers:brainstorming` a SECOND time with the implementation diff and ACs HIDDEN to generate matrix-2 (implementation-only scenarios — idempotency, concurrency, cross-wave, adversarial, observability)?
- [ ] **Step 3c**: did you UNION the two matrices, dedupe, and score each row with `Type / AC ref / Method / DB chosen`?
- [ ] **Step 3 DB routing**: is every matrix row tagged with a specific DB from the routing table (not blanket `local_acme_corp_db`)? Are the rows sorted by DB to minimize server restarts?
- [ ] **Step 4 DB swaps**: between DB groups, did you `pkill` + re-`/qspinuplocal` and verify the swap with `current_database()` before running the next group's scenarios?
- [ ] For every changed file in Step 1, can you point to a tool call where the **production trigger** for that file fired? (Not a unit test, not a REPL call — the actual HTTP request / worker run / cron invocation.)
- [ ] If the Worker layer was in scope, did you reset the entity, run the worker `--once`, and `SELECT` the resulting rows from the DB?
- [ ] Did the stack run the **fix worktree's code**, not develop? (Quick check: `ps aux | grep uvicorn` should show the worktree path. Or: edit a log line in the changed file, restart, run the trigger, confirm the log line appears.)
- [ ] Did you run against the right DB? (`psql -l` if uncertain.)
- [ ] Did at least one scenario per Type bucket (happy_path / negative / boundary / edge / auth) actually run and report PASS or FAIL with a concrete artifact (curl response, pytest function, psql output, Playwright screenshot)?
- [ ] **UUID anti-mock**: did every UI scenario that renders a UUID-typed field run against a LIVE lookup endpoint — either the LIVE Dash UI at `${{{ENV_SERVICE_URL_KEY}}}` or the harness with real hooks + CORS-bypass — NOT mocked hooks? (See §"UI Testing Anti-Mock Contract".)
- [ ] **UUID anti-mock**: did you `evaluate_script` against the rendered DOM and confirm BOTH (i) zero UUID-regex matches in user-visible text AND (ii) the expected resolved name IS present? (Both required — (i) alone misses Skeletons-forever; (ii) alone misses leaks.)
- [ ] **UUID anti-mock**: is the lookup service actually reachable (`curl -fs "${SERVICE_HEALTH}"` returns 200) BEFORE every Playwright / Chrome assertion that depends on a live lookup? Source `/tmp/{{COMPANY_SLUG}}-ports.env` first; don't assume a canonical port is bound.
- [ ] **UUID anti-mock**: if the diff added any new `resolve*Name` / `resolve*Value` call site, does the surface gate the render on `.ready` and render a Mantine `<Skeleton>` while not ready, per the `ResolvedRefCell.jsx` / `ResolvedSummaryView.jsx` convention? (Truncated-UUID placeholders like `Entity 00000000…` are NOT the convention — flag them.)

If any of those is "no", you have not done an E2E. Go back and finish, or mark BLOCKED — don't write "✅ ready" anyway.

## When to push back instead of running

- If the change is too small to need e2e (typo fix, isolated unit-tested helper), say so and skip.
- If the runtime can't be brought up after a real attempt, surface the bring-up error and ask the user to fix it before proceeding.
- If the user asked for e2e but the change is incomplete (e.g. backend ships, UI wiring is still TODO), test what's there and call out what's still untested.
