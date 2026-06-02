# Mandatory UI Regression Testing

Applies to ALL changes — including backend-only. If a backend change alters what a user sees, clicks, or receives, the UI surface MUST be tested.

## Step 1: Identify Impacted UI Pages

Trace every change to its UI surface:

1. **Direct UI changes:**
   ```bash
   git diff develop --name-only | grep "ui/pages/"
   ```
2. **API endpoint changes — find consumers:**
   ```bash
   grep -r "<endpoint_path>" {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/pages/ --include="*.py"
   ```
3. **Model/schema changes:**
   ```bash
   grep -r "<ModelName>" {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/routers/ {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/routers/ --include="*.py"
   # Then find UI pages that call those endpoints
   ```
4. **Service/repository changes:**
   ```bash
   grep -r "<service_function>" {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/routers/ {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/routers/ --include="*.py"
   ```
5. **Pipeline/worker changes:**
   ```bash
   grep -r "status" {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/pages/ --include="*.py" -l
   ```
6. **Common API → UI mappings:**

   | API Endpoint | UI Pages |
   |-------------|----------|
   | `GET /api/v1/records/` | list_page.py, ready.py, finalized.py, archived_page.py |
   | `GET /api/v1/reference-docs/` | reference_docs.py |
   | `PUT /api/v1/records/{id}` | list_page.py (edit modal) |
   | `POST /api/v1/records/{id}/finalize` | ready.py |

If you can't identify ANY impacted UI page, you haven't traced far enough.

## Step 2: Deep CRUD Test Execution

**Goal:** test every operation on every element, not just verify pages load. Bugs hide in interactions — saving, deleting, editing, modal lifecycle, dropdown population, state refresh after mutations.

For EACH impacted page:

1. `browser_navigate` to the page.
2. `browser_snapshot` to verify elements render.
3. `browser_take_screenshot` — save to `$CODEBASE_ROOT/uat/`.
4. `browser_console_messages` level="error" — any JS error = test fails.
5. `tail -20 /tmp/{{PRIMARY_REPO_NAME}}.log` and `tail -20 /tmp/{{PRIMARY_REPO_NAME}}.log` — any 500/404/timeout = investigate.

### 2a. Full CRUD Test Matrix (mandatory)

For every entity on the page (including sub-entities, nested elements, related items):

| Operation | What to verify |
|-----------|---------------|
| **CREATE** | Fill form → Save → modal closes → table refreshes → new row appears → DB confirms → no JS errors |
| **READ** | Data loads → correct values → counts match DB → nested data loads (aliases, identifiers, members, source lines) |
| **UPDATE** | Edit modal → existing data populates (incl. nested) → modify → Save → modal closes → table refreshes → DB confirms |
| **DELETE** | Click delete → confirmation → confirm → row removed → count updates → DB confirms → no JS errors |
| **TOGGLE/FILTER** | Toggle filter → results change → toggle back → original results return |

Example coverage shape (Catalog page):

```
Categories:
  - [ ] CREATE category (top-level)
  - [ ] CREATE subcategory (with parent)
  - [ ] EDIT category (rename)
  - [ ] DELETE category (soft-delete) → disappears with Active Only on
  - [ ] Toggle Active Only off → deleted category shows as inactive

Items (per category):
  - [ ] READ items list → correct count
  - [ ] CREATE item → modal closes → appears in table
  - [ ] EDIT item → modal loads with ALL existing data (description, category, type, identifiers, aliases)
  - [ ] DELETE item → removed → count decreases

Identifiers (sub-entity of item):
  - [ ] ADD identifier → Save → count increases
  - [ ] REMOVE identifier → Save → count decreases

Aliases (sub-entity of item):
  - [ ] EDIT modal loads existing aliases with correct entity names
  - [ ] ADD / REMOVE / RENAME alias → Save → DB reflects change
```

### 2b. Modal Lifecycle (where most bugs hide)

For every modal:
- [ ] Opens with correct title (Create vs Edit)
- [ ] **Edit modal loads ALL existing data** including nested (aliases, identifiers, categories, members). Confirm via server-log API calls that fetch this data.
- [ ] Required fields validated (can't save empty)
- [ ] Save → modal closes automatically
- [ ] Save → parent table refreshes with updated data
- [ ] Cancel → modal closes → no changes persisted
- [ ] After save: browser console clean (watch for 204 empty body, CORS, empty JSON parse crash)
- [ ] After save: server logs clean (404 wrong URL, 500 validation, deadlock timeout)

### 2c. Backend Pipeline Testing (UI tests can't catch these)

UI covers rendering and CRUD only. Backend pipelines (matching, classification, processing) have their own SQL, embedding, and data-flow bugs. Run pipelines directly via Python script against the test DB.

```
Prerequisites:
  - [ ] DB extensions enabled: pg_trgm (trigram), vector (pgvector)
  - [ ] the external LLM provider credentials set: LLM_PROVIDER_ENDPOINT, LLM_PROVIDER_API_KEY
  - [ ] Embeddings: configured embedding model via the external LLM provider, NOT the data warehouse

Reference matching pipeline (if feature touches matching):
  - [ ] EXACT MATCH: identical description → matched
  - [ ] TRIGRAM MATCH: similar but reordered → matched (step 3, 0.8 threshold)
  - [ ] EMBEDDING MATCH: semantically similar → matched (step 4, 0.75 threshold)
  - [ ] NO MATCH: completely new → flagged (step 7)
  - [ ] ALIAS LEARNING: after fuzzy/trigram match, alias created for future exact matching
  - [ ] REVIEW GROUPING: similar unmatched lines group under same review (0.85 embedding threshold)
  - [ ] REVIEW PROMOTION: frequency >= 3 → status changes from seen to pending
  - [ ] SQL syntax: no `::vector` casts (use `CAST(:param AS vector)`); no missing PK columns
  - [ ] Server logs after each run: no SQL errors, NOT NULL violations, extension errors

How to test:
  Write a Python script that imports RecordMatchingPipeline, creates a DB session,
  and calls match_record_lines() with test descriptions. Verify MatchOutcome fields
  and SELECT to check aliases created and reviews updated.
```

### 2d. API Response Format

For every API call the UI makes:
- [ ] DELETE returns 204 → UI handles empty response (no JSON parse crash)
- [ ] POST returns wrapped (`{"data": {...}}`) → UI unwraps correctly
- [ ] Enum values match casing (`AI` not `ai`, `PRODUCT` not `product`)
- [ ] URL paths match {{PRIMARY_REPO_NAME}} router prefixes (`line-items` not `line/items`)

## Step 3: UI Test Checklist (per page)

- [ ] Page loads without errors
- [ ] Data table renders with correct columns
- [ ] Values display correctly (amounts, dates, statuses, entity names)
- [ ] New UI elements from the feature are visible and functional
- [ ] No JS errors in browser console
- [ ] No server errors in BOTH your repos logs
- [ ] Pagination works (if applicable)
- [ ] Filters work (if applicable)
- [ ] Every CRUD operation from §2a tested and passes
- [ ] Every modal from §2b tested for full lifecycle
- [ ] State verification chain per action: UI shows change → API reflects change → DB confirms change → console clean → server logs clean. If any link fails, the test fails.

## Step 4: Screenshot Evidence

Take screenshots of every impacted page. Naming: `{TICKET}-{nn}-{page-name}.png`. Save to `$CODEBASE_ROOT/uat/`.

Example for {{JIRA_PROJECT_KEY}}-214:
```
{{JIRA_PROJECT_KEY}}214-01-home-page.png
{{JIRA_PROJECT_KEY}}214-02-pending-review.png
{{JIRA_PROJECT_KEY}}214-03-ready.png
{{JIRA_PROJECT_KEY}}214-04-finalized-records.png
{{JIRA_PROJECT_KEY}}214-05-rejected.png
{{JIRA_PROJECT_KEY}}214-06-reference-docs.png
```

## Anti-skip Rules

- **NEVER skip UI testing** because "this is a backend-only change" — if a user sees the effect, test the UI.
- **NEVER skip UI testing** because "API tests passed" — API and UI test different things.
- **NEVER skip a page** because "it probably works".
- **NEVER skip screenshots** — mandatory evidence for UAT.
- **NEVER skip sub-entity testing** — bugs hide in inner operations (aliases inside items, members inside groups), not the outer page load.
- **NEVER skip delete testing** — DELETE is the #1 silent-failure source (204 empty body, duplicate requests, stale state).
- **NEVER skip edit-modal data loading** — verify the edit modal loads ALL existing nested relations.
- **NEVER skip log checking** — after every save/delete/create, check BOTH browser console AND server logs.
- **NEVER test only the happy path** — delete the last item, create with minimum fields, edit without changing, cancel mid-edit, rapid double-click.
