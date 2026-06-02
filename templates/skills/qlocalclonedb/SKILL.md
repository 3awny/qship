---
name: qlocalclonedb
description: Clone a staging tenant's database into a named local Postgres DB for realistic local testing — copies schema + data so you can reproduce issues against production-shaped data. Use before local E2E when you need real tenant data; qspinuplocal calls it when a project ships a local-DB bootstrap.
---

# qlocalclonedb — Clone a Staging Tenant into a Named Local DB

Clones a staging tenant's the Postgres provider DB into a side-by-side local Postgres database. Lets multiple cloned tenants coexist (e.g. `{{LOCAL_DEV_DB_NAME}}` for Example Tenant plus `local_acme_corp_db` for Acme Corp) so you can switch between them without re-cloning.

**Input:** `$ARGUMENTS`
- `--tenant <name>` — exact staging tenant name (use `--list` to discover) — REQUIRED unless `--list`
- `--db-name <db>` — local Postgres DB name to create (default: `local_<sanitized_tenant>_db`)
- `--list` — list available staging tenants and exit; nothing else happens
- `--staging-url <url>` — staging `GLOBAL_DATABASE_URL` (overrides `.env.dev`). Pass inline once if `.env.dev` is missing
- `--remote-url <url>` — full Postgres URL for the tenant DB to dump from, bypassing the DB provider API lookup. Use this when the tenant's `app.account_registry` row points at a different DB provider branch than the one you want to clone (e.g. the registry pins `main`/`production` but you actually want `develop`). Supply the *pooled* DB provider endpoint URL, e.g. `postgresql://<role>:<pw>@<pooler-host>.example-postgres.com/<db>?sslmode=require`. When this is set, the local `DB_PROVIDER_API_KEY` is not used to fetch the connection string.
- `--branch-endpoint <ep-id>` — DB provider endpoint ID for a specific branch (e.g. `<branch-endpoint-id>`). Lighter-weight alternative to `--remote-url`: the skill assembles the full URL from the endpoint ID, the tenant's `db_database_name` / `db_role_name` from `app.account_registry`, and the password from the existing tenant URL pattern. Useful when you know "I want develop branch" but not the full connection string. Requires `--tenant` so role/database can be resolved.
- `--reclone` — drop the local DB if it already exists before recreating

Defaults: requires either `.env.dev` in `{{PRIMARY_REPO_NAME}}/` OR `--staging-url`. The local DB_PROVIDER_API_KEY (from `{{PRIMARY_REPO_NAME}}/.env`) is reused — except when `--remote-url` or `--branch-endpoint` is set, in which case the API lookup is skipped.

**When to override the branch.** `app.account_registry` stores ONE the Postgres provider `branch_id` per tenant. In multi-environment DB provider projects (e.g. one project hosting `main` + `develop` + per-PR preview branches), that pin usually points at `main`. If you're testing a fix against data that only exists on the `develop` branch, the default clone path pulls the wrong data — records may be missing, record_hash_id may be NULL, record_mappings rows may differ. Symptom: clone succeeds, but the rules_engine resolver returns no applicable policies because the lines aren't categorised under the expected scope. Use `--remote-url` or `--branch-endpoint` to target the right branch explicitly.

## Canonical config

| Setting | Value |
|---|---|
| {{PRIMARY_REPO_NAME}} scripts dir | `{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/scripts` |
| Wrapper template | `{{PRIMARY_REPO_NAME}}/scripts/local_setup_acmecorp.sh` (per-developer, gitignored under `scripts/local_*.sh`) |
| Local Postgres | `/opt/homebrew/opt/postgresql@17/bin/psql` |
| Local Postgres user | `{{LOCAL_DB_USER}}` |
| Underlying script | `{{PRIMARY_REPO_NAME}}/scripts/bootstrap_local_db.py` (already supports `--local-db`) |

## Protocol

### Step 1 — Argument parsing

Parse `$ARGUMENTS` for `--list`, `--tenant`, `--db-name`, `--staging-url`, `--remote-url`, `--branch-endpoint`, `--reclone`.

If `--list` AND no `--staging-url`: fall through to Step 3 with `--list-tenants`.

If neither `--list` nor `--tenant`: error and stop.

If both `--remote-url` and `--branch-endpoint` are passed: `--remote-url` wins (more specific).

### Step 2 — Preflight

```bash
# Postgres running?
/opt/homebrew/opt/postgresql@17/bin/psql -U {{LOCAL_DB_USER}} -d postgres -c "SELECT 1" > /dev/null 2>&1 \
  || { echo "❌ Postgres not on :5432"; exit 1; }

# {{PRIMARY_REPO_NAME}}/.env exists (we always need DB_PROVIDER_API_KEY from it)?
test -f {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/.env || { echo "❌ {{PRIMARY_REPO_NAME}}/.env missing"; exit 1; }

# Need staging GLOBAL_DATABASE_URL: prefer --staging-url, then .env.dev
if [ -n "$STAGING_URL_ARG" ]; then
  STAGING_URL="$STAGING_URL_ARG"
elif [ -f {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/.env.dev ]; then
  STAGING_URL="$(grep '^GLOBAL_DATABASE_URL=' {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/.env.dev | cut -d= -f2-)"
else
  echo "❌ Need staging GLOBAL_DATABASE_URL — pass --staging-url or restore .env.dev"
  exit 1
fi
```

### Step 3 — Build the runtime env file

`bootstrap_local_db.py` calls `load_dotenv(env_path, override=True)` which would clobber any pre-exported staging URL. Build a temp env file combining the staging URL (for account_registry lookup) with the local DB_PROVIDER_API_KEY (for DB provider API auth):

```bash
TMP_ENV="$(mktemp -t qlocalclonedb.XXXXXX)"
trap 'rm -f "$TMP_ENV"' EXIT
DB_PROVIDER_KEY="$(grep '^DB_PROVIDER_API_KEY=' {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/.env | cut -d= -f2-)"
[ -z "$DB_PROVIDER_KEY" ] && { echo "❌ DB_PROVIDER_API_KEY missing from {{PRIMARY_REPO_NAME}}/.env"; exit 1; }
printf 'GLOBAL_DATABASE_URL=%s\nDB_PROVIDER_API_KEY=%s\n' "$STAGING_URL" "$DB_PROVIDER_KEY" > "$TMP_ENV"
```

### Step 4 — Patch PSQL_BIN for this machine

`bootstrap_local_db.py` hardcodes `PSQL_BIN = "/Applications/Postgres.app/..."` which doesn't exist on this dev box (we use brew). Make a temp copy of the script with PSQL_BIN replaced — DO NOT edit the committed file:

```bash
PSQL_BIN_LOCAL="/opt/homebrew/opt/postgresql@17/bin/psql"
[ -x "$PSQL_BIN_LOCAL" ] || { echo "❌ psql not at $PSQL_BIN_LOCAL"; exit 1; }
TMP_SCRIPT="$(mktemp -t qlocalclonedb_script.XXXXXX.py)"
trap 'rm -f "$TMP_ENV" "$TMP_SCRIPT"' EXIT
sed "s|^PSQL_BIN = .*|PSQL_BIN = \"$PSQL_BIN_LOCAL\"|" \
  {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/scripts/bootstrap_local_db.py > "$TMP_SCRIPT"
```

### Step 4.5 — (optional) Override the remote URL to clone from a specific branch

`bootstrap_local_db.py` resolves the tenant DB URL via DB provider API at `main()` time:

```python
remote_url = get_source_connection_string(tenant, db_provider_api_key)
```

That uses `tenant.db_branch_id` from `app.account_registry` — which is usually pinned to a single branch (often `main`). If the caller passed `--remote-url` or `--branch-endpoint`, patch the temp script to replace that line with the override:

```bash
# Build the override URL
if [ -n "$REMOTE_URL_ARG" ]; then
  OVERRIDE_URL="$REMOTE_URL_ARG"
elif [ -n "$BRANCH_ENDPOINT_ARG" ]; then
  # Assemble URL from endpoint + account_registry row.
  # Look up role + database from account_registry on the staging GLOBAL DB.
  read DB_ROLE_NAME DB_DATABASE < <(/opt/homebrew/opt/postgresql@17/bin/psql "$STAGING_URL" -tAF' ' -c \
    "SELECT db_role_name, db_database_name FROM app.account_registry WHERE tenant_name='$TENANT'")
  # Password isn't in account_registry — db_provider_client builds it via API normally.
  # The pragmatic path: ask the user to pass --remote-url for first-time use, then they can
  # paste the resulting URL into a comment on this skill so the next invocation
  # has a known-good template. For a fully automated --branch-endpoint flow, the
  # the_db_provider API call must be invoked to mint a fresh password against the endpoint.
  echo "❌ --branch-endpoint requires a one-time DB_PROVIDER_API_KEY with project access."
  echo "   For now, pass --remote-url with the full URL (you can find it in the the Postgres provider console"
  echo "   under the chosen branch's 'Connection string' panel)."
  exit 1
fi

# Patch the temp script. Done via a small Python helper file (sed can't safely
# handle the URL's `&` because it's the sed-replacement back-reference).
if [ -n "$OVERRIDE_URL" ]; then
  printf '%s\n' "$OVERRIDE_URL" > /tmp/_qlocalclonedb_remote_url.txt
  TMP_SCRIPT="$TMP_SCRIPT" python3 - <<'PY'
import os
path = os.environ["TMP_SCRIPT"]
with open(path) as f: src = f.read()
with open("/tmp/_qlocalclonedb_remote_url.txt") as f: url = f.read().strip()
needle = "remote_url = get_source_connection_string(tenant, db_provider_api_key)"
repl   = f'remote_url = "{url}"  # OVERRIDDEN by qlocalclonedb (--remote-url / --branch-endpoint)'
assert needle in src, "needle not found — bootstrap_local_db.py changed shape"
with open(path, "w") as f: f.write(src.replace(needle, repl))
print("patched remote_url override")
PY
  rm -f /tmp/_qlocalclonedb_remote_url.txt
fi
```

If neither override is set, leave the script alone and let it use the DB provider API + account_registry path.

### Step 5 — List or clone

If `--list`:
```bash
cd {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}
./venv/bin/python "$TMP_SCRIPT" --list-tenants --env-file "$TMP_ENV"
exit 0
```

Otherwise:
```bash
DB_NAME="${DB_NAME:-local_$(echo "$TENANT" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')_db}"
cd {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}

# --reclone semantics: bootstrap_local_db.py drops + recreates by default,
# but only the DB it's targeting. So just pass --local-db.
./venv/bin/python "$TMP_SCRIPT" \
  --tenant "$TENANT" \
  --local-db "$DB_NAME" \
  --env-file "$TMP_ENV"
```

### Step 6 — Capture tenant UUID for spinup

Read the freshly-cloned tenant's UUID from `account_registry` so the user can pass it to `/qspinuplocal`:

```bash
TENANT_UUID="$(/opt/homebrew/opt/postgresql@17/bin/psql -U {{LOCAL_DB_USER}} -d "$DB_NAME" -t -A \
  -c "SELECT tenant_id FROM app.account_registry LIMIT 1")"
```

### Step 7 — Report

```
LOCAL CLONE COMPLETE
====================
Tenant: <TENANT> (<TENANT_UUID>)
Local DB: <DB_NAME>

Counts:
  organizations: <N>
  parties:       <N>
  documents:     <N>
  lines:         <N>

To start the stack against this DB:

  /qspinuplocal --db-name <DB_NAME> --tenant-uuid <TENANT_UUID>

(/qspinuplocal will rewrite {{PRIMARY_REPO_NAME}}/.env to point here — see
its docs for the override=True caveat.)

Coexists with: any other local_*_db you've cloned (run psql -l to list).
```

## Critical caveat — {{PRIMARY_REPO_NAME}} config.py override=True

`{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/config.py:15` calls `load_dotenv(override=True)` at import time, which OVERRIDES any env vars exported on the command line with whatever is in `{{PRIMARY_REPO_NAME}}/.env`.

**Implication for this skill**: cloning the DB is fine, but the spinup wrapper MUST rewrite `{{PRIMARY_REPO_NAME}}/.env` to point at the new DB before starting the {{PRIMARY_REPO_NAME}} process. Exporting `DATABASE_URL` / `GLOBAL_DATABASE_URL` / `ENFORCE_DEV_DATABASE_URL` is NOT enough — they get clobbered at import.

`/qspinuplocal` handles the rewrite. This skill (`qlocalclonedb`) only clones; it does NOT touch `.env`.

The right long-term fix is to change `override=True` → `override=False` in `{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/config.py` so command-line env wins. That's a separate code change pending review.

## Anti-patterns

- ❌ Don't edit `{{PRIMARY_REPO_NAME}}/scripts/bootstrap_local_db.py` to change `PSQL_BIN` — it's committed code. Patch a temp copy.
- ❌ Don't write the staging `GLOBAL_DATABASE_URL` (or `--remote-url`) to a tracked file. Either pass inline at invocation time or keep it in `.env.dev` (gitignored).
- ❌ Don't reuse `{{LOCAL_DEV_DB_NAME}}` as the DB name for other tenants — the existing Example Tenant clone gets clobbered.
- ❌ Don't commit `{{PRIMARY_REPO_NAME}}/scripts/local_*.sh` wrappers — they're gitignored under `scripts/local_*.sh` for a reason.
- ❌ Don't use `sed` to inject `--remote-url` into the temp script. The URL contains `&` (a query-string separator), which `sed` interprets as the entire matched pattern in the replacement, producing a corrupted URL. Use the Python helper shown in Step 4.5.

## Known surprise — `app.account_registry.db_branch_id` is a single pin

Staging tenant rows pin ONE branch (typically the production/main branch). If you `--tenant "Foo"` without overriding the URL, you clone from that pinned branch, not from the develop branch you might assume. Verify with:

```bash
psql "$STAGING_URL" -c "SELECT tenant_name, db_branch_id FROM app.account_registry WHERE tenant_name='<name>';"
```

If the `db_branch_id` doesn't match the branch where the data you want to test against actually lives, you have two options:

1. Pass `--remote-url` with the develop branch's pooled URL (find it in the Postgres provider console → Branches → Connection string).
2. Open a one-off `UPDATE` on staging `app.account_registry` to repoint — generally a bad idea; affects every other developer.

Option 1 is right ~always.

## Related

- `/qspinuplocal --db-name <DB_NAME>` — start the stack against any cloned DB
- `{{PRIMARY_REPO_NAME}}/scripts/bootstrap_local_db.py` — the underlying script (already `--local-db` aware)
- `{{PRIMARY_REPO_NAME}}/scripts/local_setup_acmecorp.sh` — example per-developer wrapper (gitignored)
