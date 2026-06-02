# qship — split-evidence contract & E2E evidence format (reference)

Extracted from `SKILL.md`. Read when producing or validating
`phase3-evidence.md` (API + UI evidence, Playwright reporter setup, escape
rationales, and how to debug a hook block).

---

### Split-evidence contract (API + UI)

The rule enforced by both hooks:

- **API E2E is ALWAYS required when the diff touches any `{{CODEBASE_PATH_PREFIX}}/**/api/**/*.py` file.**
- **UI E2E is required when the diff touches any UI file (`*.tsx`, `*.jsx`, `*/ui/**`, `*/components/react/**`, `*/dash_pages/**`) OR when a changed endpoint is referenced by any UI source.**
- Changes that touch neither API nor UI (migrations, docs, internal helpers) need no E2E evidence — but you still need `pipeline-context.json` proving the classification.

Phase 1 (implementation) subagent MUST invoke after writing code:
```bash
bash ~/.claude/skills/qship/hooks/qship-compute-context.sh <TICKET_ID>
# writes {{STATE_ROOT}}/worktrees/<TICKET>/pipeline-context.json
```

Phase 3 (E2E) subagent — `/qe2etest` — MUST produce `phase3-evidence.md` with two sections. Both hooks validate against `pipeline-context.json`:

```markdown
## API Evidence
# Required when pipeline-context.json says api_changed=true.
# Acceptable content:
#   - One or more HTTP blocks with curl/httpx and status codes, OR
#   - The rationale: "no api surface: <why this change has no HTTP surface>"
curl -sS http://localhost:9000/api/v1/organizations/abc/aliases → HTTP 200
{"id":"abc","aliases":[...]}
curl -sS http://localhost:9000/api/v1/organizations/abc/aliases → HTTP 201

## UI Evidence
# Required when ui_changed=true OR ui_consumer_changed=true.
# Acceptable content (ANY ONE of the following):
#   - A Playwright results.json path + a trace.zip path.
#     The hook runs: jq '.stats.unexpected == 0 and .stats.expected > 0'
#   - A trace.zip path alone (hook verifies file exists).
#   - Rationale: "no ui surface: <why this backend change doesn't reach a UI consumer>"
#   - Escape: "QSHIP_SKIP_UI_E2E: <reason and follow-up plan>"
Playwright report: test-results/playwright-results.json
Trace: test-results/trace-organizations-aliases.zip
Accessibility snapshot: test-results/a11y-org-detail.yaml
```

### Playwright reporter setup for qmanualt

When `/qmanualt` runs a UI flow, it MUST configure Playwright to emit a JSON report the hook can read:

```bash
# Option A — env var (works with any playwright config):
export PLAYWRIGHT_JSON_OUTPUT_FILE={{STATE_ROOT}}/worktrees/<TICKET>/test-results/playwright-results.json
npx playwright test --reporter=json,html
# Option B — via playwright.config.ts:
# reporter: [['json', { outputFile: 'test-results/playwright-results.json' }], ['html']]
```

Traces MUST be on so `trace.zip` lands under `test-results/`:
```ts
// playwright.config.ts
use: { trace: 'on' }
```

Output paths must be under `{{STATE_ROOT}}/worktrees/<TICKET>/` OR be relative paths listed in `phase3-evidence.md` (hooks resolve relative-to-ticket-dir automatically).

### Escape rationales

When a change genuinely has no API or UI surface, write an explicit rationale that cites the changed files:

```markdown
## API Evidence
no api surface: changed only {{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/models/orders.py (SQLAlchemy column addition), no router touched.

## UI Evidence
no ui surface: same change — no frontend references to new column; will surface once downstream {{JIRA_PROJECT_KEY}}-XYZ ships UI.
```

For temporary infrastructure outages where UI regression can't run:
```markdown
## UI Evidence
QSHIP_SKIP_UI_E2E: staging the external auth provider tenant offline temporarily; API regression covers the changed endpoint. Follow-up: rerun UI regression on {{JIRA_PROJECT_KEY}}-XYZ after outage.
```

### Debugging hook blocks

```bash
# See what context the classifier computed:
jq . {{STATE_ROOT}}/worktrees/<TICKET>/pipeline-context.json

# See exactly why the Stop hook would block:
echo '{"stop_hook_active": false}' | bash ~/.claude/skills/qship/hooks/require-pipeline-complete.sh

# Re-run context computation after more code changes:
bash ~/.claude/skills/qship/hooks/qship-compute-context.sh <TICKET>

# Clear a stuck pipeline (pipeline was abandoned):
rm -rf {{STATE_ROOT}}/worktrees/<TICKET>
```
