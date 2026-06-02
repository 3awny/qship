# Test Data Strategy

The local DB is a clone of staging — fully local, isolated, disposable. No shared-state conflicts.

## Local DB (default — free writes)

INSERT/UPDATE/DELETE freely. Per memory `feedback_local_db_auto_approved`, writes against `localhost:5432/{{LOCAL_DEV_DB_NAME}}` are pre-authorised — no permission prompt.

**Re-clone to reset:**
```bash
cd "$CODEBASE_ROOT/{{PRIMARY_REPO_NAME}}"
python scripts/bootstrap_local_db.py --tenant "Example Tenant" --env-file .env.dev
```

## Database helpers

```python
import psycopg2
conn = psycopg2.connect("postgresql://{{LOCAL_DB_USER}}@localhost:5432/{{LOCAL_DEV_DB_NAME}}")
cursor = conn.cursor()

# READ-ONLY (always free)
cursor.execute("SELECT * FROM public.record WHERE status = 'NEW' LIMIT 5")
rows = cursor.fetchall()

# WRITE — auto-approved against local DB
cursor.execute("INSERT INTO ...")
conn.commit()
```

```bash
# Direct psql access
/opt/homebrew/opt/postgresql@17/bin/psql -U {{LOCAL_DB_USER}} -d {{LOCAL_DEV_DB_NAME}}
```

## Loading credentials in custom scripts

Scripts that need external service auth (LLM providers, data warehouse, document-AI provider) load from `{{PRIMARY_REPO_NAME}}/.env`:

```python
import sys, os
sys.path.insert(0, os.environ["CODEBASE_ROOT"] + "/{{PRIMARY_REPO_NAME}}")
sys.path.insert(0, os.environ["CODEBASE_ROOT"] + "/{{PRIMARY_REPO_NAME}}")

from dotenv import load_dotenv
load_dotenv(os.environ["CODEBASE_ROOT"] + "/{{PRIMARY_REPO_NAME}}/.env")
```

Available env vars: `ANTHROPIC_API_KEY`, `DATA_PLATFORM_CLIENT_ID`, `DATA_PLATFORM_CLIENT_SECRET`, `DATA_PLATFORM_TOKEN`, `DATA_PLATFORM_HOST`, `LLM_PROVIDER_ENDPOINT`, `LLM_PROVIDER_API_KEY`, `LLM_PROVIDER_API_VERSION`. Always use `python-dotenv`. Never hardcode secrets.

## Staging fallback (rare — explicit user request only)

qmanualt MUST refuse silent staging routing. Default is always the local cloned DB. If the user explicitly says "test against staging":

1. Capture credentials from the project's `.env.dev` (`{{ENV_CLOUD_URL_KEY}}`, `{{ENV_OAUTH_CLIENT_ID_KEY}}`, `{{ENV_OAUTH_CLIENT_SECRET_KEY}}`, `DATABASE_URL`) — do NOT inline them.
2. Use the old revert strategy:
   1. SELECT current state of rows you'll modify.
   2. Permission prompt with exact SQL.
   3. Minimal targeted writes.
   4. Run tests.
   5. Revert immediately after.
   6. SELECT to confirm revert.

## Reset after testing

- **Downgrade migrations** if you want to preserve data: `alembic downgrade <previous_version>`
- **Re-clone from staging** for a fresh start: `python scripts/bootstrap_local_db.py --tenant "Example Tenant" --env-file .env.dev`

If testing against shared staging (rare), always downgrade migrations back to original versions.

## Constants

| Variable | Value |
|----------|-------|
| Example Tenant Project ID | `your-db-project-id` |
| Example Tenant Dev Branch | `your-db-branch-id` |
| Example Tenant Tenant ID | `00000000-0000-0000-0000-000000000000` |

With local DB, you rarely need direct staging access — the local DB is already a clone of Example Tenant staging data.
