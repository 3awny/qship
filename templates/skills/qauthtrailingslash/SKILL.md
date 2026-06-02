---
name: qauthtrailingslash
description: Audit API routes for the trailing-slash / 307-redirect auth bug — where a missing or extra trailing slash makes the server issue an HTTP 307 redirect and the client silently drops the Authorization header, causing intermittent 401s. Use when reviewing or debugging FastAPI/Starlette (or similar) routes, auth-token loss across redirects, or flaky authenticated endpoints.
---

# qauthtrailingslash — Trailing-slash / 307-redirect audit

Audits every client URL in changed code against the FastAPI route definitions, reporting any mismatch that would 307-redirect at runtime. On cross-origin staging deployments, those 307s strip the `Authorization` header, so the request silently succeeds-as-401 and the UI shows empty data with no error.

> **Multi-repo contract:** Runs across every repo in `$SKILLS_ROOT/qship/repos.json` that contains FastAPI route definitions. Single-repo users see one service's routes audited. Multi-service users see all services audited and any cross-service URL mismatch flagged.

This is an **autonomous, machine-checkable** audit — no human judgement required. Run it before merge on any PR that adds or moves an HTTP call.

## Why this matters (the failure mode)

Memory references:
- `feedback_fastapi_trailing_slash_redirect.md` — POST to a route without trailing slash, when the server route has one (or vice versa), gets a 307 redirect from FastAPI's default `redirect_slashes=True`.
- `feedback_cross_origin_redirect_strips_auth.md` — Browsers strip the `Authorization` header on cross-origin redirects (CORS). Staging serves UI and API from different origins, so the redirect lands on the API as **unauthenticated**.

Symptom: silent empty-data UI on staging that works fine locally (same-origin in dev). Fingerprint: a `307` followed by a `401` in the network tab; your repo logs show "No credentials provided".

## What the audit checks

For every `.jsx` / `.tsx` / `.ts` / `.js` / `.py` file in the diff (or current branch vs `develop`):

1. **Parse client URLs** — extract every fetch / callApi / callApiAbs / `_clientRequest` / `_doRequest` / curl / `httpx` call's URL.
2. **Parse FastAPI routes** — for every `.py` file under `{{CODEBASE_PATH_PREFIX}}/*/api/v1/*.py`, find each router declaration (`APIRouter(prefix="/...")`) and each handler decorator (`@router.<method>("/...")`). Resolve to the full URL.
3. **Cross-check** — for each client URL, locate its matching server route by path-template + method. Report a **mismatch** when:
   - Server has trailing slash, client doesn't (POST/PATCH/PUT will 307).
   - Client has trailing slash, server doesn't.
   - Method/path otherwise match but slash position differs.

## Argument parsing

Parse `$ARGUMENTS` to extract optional PR URL(s) or repo paths.

- **No args** → audit current branch in the cwd against `develop`.
- **One or more PR URLs** → check out each PR's branch, audit, restore.
- **A repo path** → audit that repo's current branch against `develop`.

## Steps

### Step 1 — Resolve scope

If a PR URL is provided, derive `<REPO_PATH>` from the URL using the standard mapping:

| Repo | Local path |
|---|---|
| `{{PRIMARY_REPO_NAME}}` | `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}` |
| `{{PRIMARY_REPO_NAME}}` | `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}` |
| `{{PRIMARY_REPO_NAME}}` | `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}` |

Fetch + checkout the PR branch in that repo path.

If no PR provided, use the current cwd. Fail loudly if cwd isn't one of the three repos.

### Step 2 — Build the route table

Parse every `.py` file under `<REPO_PATH>/{{CODEBASE_PATH_PREFIX}}/**/api/v1/*.py`:

```python
# pseudo
for py_file in glob("{{CODEBASE_PATH_PREFIX}}/**/api/v1/*.py", recursive=True):
    src = open(py_file).read()
    # 1. Find APIRouter declarations and their prefixes
    # 2. Find @<router>.<method>("/...") decorators
    # 3. Resolve full path = router.prefix + decorator path
    # 4. Record (method, full_path) -> py_file:line
```

Cross-repo audits: when the changed repo is {{PRIMARY_REPO_NAME}} but a UI call goes to {{PRIMARY_REPO_NAME}} (cross-repo URLs use `apiBaseUrl` / `callApi` / `callApiAbs`), parse {{PRIMARY_REPO_NAME}}'s routes too.

Output a route table:
```
GET    /organizations/{organization_id}/subjects/         {{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/api/v1/subjects.py:62
POST   /organizations/{organization_id}/subjects/         {{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/api/v1/subjects.py:208
GET    /organizations/{organization_id}/subjects/{subject_id}  {{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/api/v1/subjects.py:142
...
```

### Step 3 — Build the client URL list

For every changed `.jsx`/`.tsx`/`.ts`/`.js` file in the diff:

```bash
git -C <REPO_PATH> diff develop --name-only -- '*.jsx' '*.tsx' '*.ts' '*.js'
```

Parse out client URL calls. Patterns to extract:

```
# Direct fetch
fetch(`${base}/api/v1/.../...`)
fetch("/api/v1/...")

# Per-entity API helpers ({{PRIMARY_REPO_NAME}})
callApi("/...")            # path resolved against /api/v1/organizations/{orgId}
callApiAbs("${baseUrl}/...")  # absolute URL — extract path

# Policy API ({{PRIMARY_REPO_NAME}}-side)
_clientRequest("POST", "/...")   # path resolved against /api/v1/policies
_doRequest("GET", `/${id}`)          # same

# Curl / httpx (Python or shell)
curl ... "/api/v1/..."
httpx.get("/api/v1/...")
```

For each match, record `(method, resolved_path, file:line)`.

**Resolution rules:**
- `callApi(path)` resolves to `/api/v1/organizations/{orgId}{path}` against {{PRIMARY_REPO_NAME}}.
- `callApiAbs(absolute_url)` — extract the `/api/v1/...` substring.
- `_clientRequest(method, path)` resolves to `/api/v1/policies{path}` against {{PRIMARY_REPO_NAME}}.
- `_doRequest(method, path)` (inside recordApi.js) — same as `_clientRequest`.

### Step 4 — Cross-check + report

For each client URL `(method, path)`:

1. Look for an exact server-route match. If found → ✓.
2. If not found, look for a match with the trailing slash flipped:
   - Client has trailing slash, server doesn't → **⚠️ FLIP-LIKELY-307**.
   - Server has trailing slash, client doesn't → **⚠️ FLIP-LIKELY-307**.
3. If still not found → ⚠️ **NO-MATCHING-ROUTE** (might be a typo, removed endpoint, or cross-repo URL whose target wasn't parsed).

Output as a table:

```
TRAILING-SLASH AUDIT — <repo> @ <branch>
========================================

Client URLs scanned: 23
Server routes parsed: 412
Matched cleanly:     23 ✓
Slash mismatches:    0
Unmatched paths:     0
```

When mismatches exist:

```
⚠ MISMATCHES (would 307-redirect on cross-origin staging):

  1. POST /api/v1/policies/training
     Client: shared/recordApi.js:473  → "/training"  (no trailing slash)
     Server: api/v1/records.py:721   → "/training/" (trailing slash)
     Fix:    change client to "/training/" or server to "/training"

  ...
```

### Step 5 — Severity classification

Not every mismatch is critical. Classify:

| Method | Trailing slash impact |
|---|---|
| **POST / PUT / PATCH / DELETE** | **HIGH** — body + auth header **stripped on the 307 redirect** in cross-origin context. Silent fail. |
| GET (read-only, no body) | MEDIUM — request still completes via the 307→GET, but adds a round trip. Authorization header IS preserved on cross-origin GET redirects in modern browsers, BUT not on Safari + some proxies. Treat as still worth fixing. |

Mismatches MUST be fixed (HIGH) or surfaced as a known minor (MEDIUM), never silently accepted.

### Step 6 — Anti-patterns to flag separately

While scanning, also call out:

- **Hard-coded absolute URLs to a sibling service** that ignore the configured base URL (e.g. `fetch("http://{{PRIMARY_REPO_NAME}}...")` or relative `/api/v1/policies/...` calls when {{PRIMARY_REPO_NAME}} now ships the per-tenant `appApiUrl` config knob). These should go through the configured-base-URL helper.
- **`fetch(...)` directly inside a component** instead of through the per-entity API module. Cite the CLAUDE.md anti-pattern bullet.

### Step 7 — Exit code + summary

- All client URLs match → exit 0 with summary.
- Any HIGH mismatch → exit 1 with the table; the user must fix before merge.
- Only MEDIUM mismatches → exit 0 but print the table prominently.

## Implementation note

The implementation may be a Python script rather than pure shell — easier to parse APIRouter prefixes + decorator path strings reliably. A reasonable starting shape lives at `~/.claude/scripts/qauthtrailingslash.py`; the command may invoke it via `python ~/.claude/scripts/qauthtrailingslash.py [args]`.

If a clean implementation isn't obvious, fall back to a guided audit: enumerate the changed client URLs and the matching server-route paths inline in the chat, then ask the user to confirm each match or flip.

## Output rules

- Always print the route table count and the client-URL count up front.
- Always show the actual file:line citations for any mismatch — reviewers must be able to click into the code.
- Never auto-fix. The fix could be at either side (client or server) and that's a domain decision.

## Related commands

- `/qfixci` — runs after CI failures; trailing-slash bugs typically don't fail CI but DO fail on staging post-deploy.
- `/qmanualt` — E2E tests on staging will catch these as silent empty-UI symptoms; this command catches them earlier.
