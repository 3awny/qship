# Epic Integration Testing (Multi-Ticket / Multi-Branch / Cross-Repo)

When testing an epic with multiple tickets that span different branches and/or repos, **automatically create a combined integration branch** before running E2E tests. This ensures the full feature is tested end-to-end rather than each ticket in isolation.

All paths use `$CODEBASE_ROOT` (resolved in SKILL.md). All writes against the local DB are auto-approved per the permission contract.

## When to create integration branches

ANY of:
- Epic has 2+ tickets in the **same repo** on different branches
- Epic has tickets across **different repos** (any combination in your repos.json)
- User asks to test "the full epic" or "end to end"

## Step 1: Identify epic branches

```bash
# Worktrees for this epic
ls -la {{STATE_ROOT}}/worktrees/<EPIC_ID>/

# Or list branches by epic prefix in each repo
for repo in $(jq -r ".[].name" "$SKILLS_ROOT/qship/repos.json"); do
  echo "=== $repo ==="
  git -C "$CODEBASE_ROOT/$repo" branch | grep "<EPIC_ID>\|<TICKET_PREFIX>"
done
```

## Step 2: Create integration branch per repo

For each repo with multiple ticket branches:

```bash
EPIC_ID="{{JIRA_PROJECT_KEY}}-139"
REPO_PATH="$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}"
INTEGRATION_BRANCH="integration/${EPIC_ID}-e2e-test"

cd "$REPO_PATH"
git checkout develop && git pull origin develop
git checkout -b "$INTEGRATION_BRANCH"
git merge --no-ff <WAVE_1_BRANCH>
git merge --no-ff <WAVE_2_BRANCH>
# Resolve any conflicts — they reveal real integration issues
```

Repos with one ticket branch: skip the integration branch, use that branch directly.

## Step 3: Create integration worktree

```bash
mkdir -p {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration

git -C "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}" worktree add \
  {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration/{{PRIMARY_REPO_NAME}} \
  integration/${EPIC_ID}-e2e-test

git -C "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}" worktree add \
  {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration/{{PRIMARY_REPO_NAME}} \
  <TICKET_BRANCH>

# Copy .env files
cp "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}/.env" \
   {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration/{{PRIMARY_REPO_NAME}}/.env
cp "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}/.env" \
   {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration/{{PRIMARY_REPO_NAME}}/.env
```

## Step 4: Run migrations in dependency order

```bash
LOCAL_DB="postgresql://{{LOCAL_DB_USER}}@localhost:5432/{{LOCAL_DEV_DB_NAME}}"
INTEGRATION_DIR="{{STATE_ROOT}}/worktrees/${EPIC_ID}-integration"

# 1. {{PRIMARY_REPO_NAME}} first (shared/primary schema)
cd "$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}"
export PYTHONPATH="$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}:$PYTHONPATH"
export DATABASE_URL="$LOCAL_DB"
"$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}/venv/bin/python" -m alembic upgrade head

# 2. {{PRIMARY_REPO_NAME}} second (depends on {{PRIMARY_REPO_NAME}})
cd "$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}"
export PYTHONPATH="$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}:$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}:$PYTHONPATH"
export DATABASE_URL="$LOCAL_DB"
"$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}/venv/bin/python" -m alembic upgrade head
```

Migrations against the local DB are auto-approved per the permission contract.

## Step 5: Start services from integration worktrees

```bash
INTEGRATION_DIR="{{STATE_ROOT}}/worktrees/${EPIC_ID}-integration"
LOCAL_DB="postgresql://{{LOCAL_DB_USER}}@localhost:5432/{{LOCAL_DEV_DB_NAME}}"

# {{PRIMARY_REPO_NAME}} from integration worktree
cd "$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}"
DEV_MODE=true \
  ENFORCE_DEV_DATABASE_URL="$LOCAL_DB" \
  GLOBAL_DATABASE_URL="$LOCAL_DB" \
  DEV_TENANT_ID="00000000-0000-0000-0000-000000000000" \
  PYTHONPATH="$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}:$PYTHONPATH" \
  "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}/venv/bin/python" serve.py > /tmp/{{PRIMARY_REPO_NAME}}-integration.log 2>&1 &

# {{PRIMARY_REPO_NAME}} from integration worktree
cd "$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}"
DEV_MODE=true \
  DATABASE_URL="$LOCAL_DB" \
  GLOBAL_DATABASE_URL="$LOCAL_DB" \
  ENFORCE_DEV_DATABASE_URL="$LOCAL_DB" \
  {{ENV_SERVICE_URL_KEY}}="http://127.0.0.1:9000" \
  PYTHONPATH="$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}:$INTEGRATION_DIR/{{PRIMARY_REPO_NAME}}:$PYTHONPATH" \
  "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}/venv/bin/python" serve.py > /tmp/{{PRIMARY_REPO_NAME}}-integration.log 2>&1 &

sleep 8
curl -s http://127.0.0.1:9000/health && echo " - {{PRIMARY_REPO_NAME}} OK"
curl -s http://127.0.0.1:8000/health && echo " - {{PRIMARY_REPO_NAME}} OK"
```

## Step 6: Run E2E

Proceed with normal testing workflow against the integration servers. All epic changes are now visible across repos.

## Step 7: Cleanup

```bash
git -C "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}" worktree remove \
  {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration/{{PRIMARY_REPO_NAME}} 2>/dev/null
git -C "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}" worktree remove \
  {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration/{{PRIMARY_REPO_NAME}} 2>/dev/null

git -C "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}" branch -D integration/${EPIC_ID}-e2e-test 2>/dev/null
git -C "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}" branch -D integration/${EPIC_ID}-e2e-test 2>/dev/null

rmdir {{STATE_ROOT}}/worktrees/${EPIC_ID}-integration 2>/dev/null
```

## Merge conflict during integration = real bug

If `git merge` fails with conflicts when creating the integration branch:
1. **Same-repo conflicts** — two branches modified the same code. Resolve manually and note in the test report.
2. **Cross-repo contract mismatch** — one repo expects an API shape another doesn't provide. This MUST be fixed in the individual ticket branches before E2E proceeds.

Report merge conflicts to the user immediately — they signal the epic's PRs will conflict on develop too.

## Cherry-picking fixes back to feature branches

If you fixed bugs while running the integration test, **don't cherry-pick from inside qmanualt**. Hand off to `/qpr` — that skill owns commit/push/PR mechanics and will coordinate the cherry-pick into each affected feature branch with permission prompts.
