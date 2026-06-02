---
name: qspinuplocal
description: Spin up your primary service locally against a local Postgres DB for testing — env wiring, optional migrations, health check. Single-service by design; adapt the start command to your stack.
---

# qspinuplocal — Spin Up the Local Stack

Starts your **primary repo's** service against a local Postgres database so `/qe2etest` and `/qmanualt` have a real (not mocked) target to drive.

> **Scope — read this first.** Local-stack spin-up is the single most stack-specific thing in qship: every codebase starts differently (uvicorn, gunicorn, `manage.py runserver`, `npm run dev`, `docker compose up`, a Procfile, a Makefile target). This skill therefore does the **portable** parts well — DB existence check, port-collision handling, the `load_dotenv(override=True)` footgun, worktree `.env` safety, a shared `ports.env` contract for downstream skills — and starts **one service** (your primary repo, resolved from `$SKILLS_ROOT/qship/repos.json`). If you run multiple services locally (a worker, a sibling API, a separate frontend), start those the same way or adapt the Step 5 start command. Treat the bash below as a reference recipe, not a turnkey generic orchestrator.

**Input:** `$ARGUMENTS`
- `--db-name <db>` — local Postgres DB to start against (default: `{{LOCAL_DEV_DB_NAME}}`). Must already exist — clone via `/qlocalclonedb` first if your project supports it.
- `--tenant-uuid <uuid>` — optional `DEV_TENANT_ID` to inject (multi-tenant apps); if omitted, looked up from `<db>.app.account_registry` when that table exists.
- `--worktree <path>` — the checkout to run against. Defaults to an auto-detected worktree under `{{STATE_ROOT}}/worktrees/<TICKET>/`, else refuses the maintree unless `--allow-maintree`.
- `--start-cmd "<cmd>"` — override the service start command (default tries the project's configured runner).
- `--port <n>` — preferred port (default `8000`, with a collision-fallback ladder).
- `--worker` — also start a background worker process if your stack has one (best-effort).

## Resolve the target repo

```bash
REPO_NAME="$(jq -r '(.[] | select(.is_primary==true) | .name) // .[0].name' "$SKILLS_ROOT/qship/repos.json")"
REPO_SCHEMA="$(jq -r '(.[] | select(.is_primary==true) | .schema) // .[0].schema // "public"' "$SKILLS_ROOT/qship/repos.json")"
REPO_PORT="$(jq -r '(.[] | select(.is_primary==true) | .port) // .[0].port // 8000' "$SKILLS_ROOT/qship/repos.json")"
echo "Primary repo: $REPO_NAME (schema=$REPO_SCHEMA, default port=$REPO_PORT)"
```

## Protocol

### Step 0 — Resolve --db-name, --tenant-uuid, and the worktree path

```bash
DB_NAME="${DB_NAME:-{{LOCAL_DEV_DB_NAME}}}"

# Verify the DB exists locally
psql -U {{LOCAL_DB_USER}} -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 \
  || { echo "❌ DB '$DB_NAME' does not exist. Create it (or run /qlocalclonedb) first."; exit 1; }

# Multi-tenant apps only: resolve a tenant UUID from the DB if not supplied.
if [ -z "${TENANT_UUID:-}" ]; then
  TENANT_UUID="$(psql -U {{LOCAL_DB_USER}} -d "$DB_NAME" -tAc \
    'SELECT tenant_id FROM app.account_registry LIMIT 1' 2>/dev/null || true)"
fi
echo "Using DB=$DB_NAME${TENANT_UUID:+ tenant_uuid=$TENANT_UUID}"
```

#### Step 0.5 — Resolve the worktree (worktree-isolation contract)

This skill MUTATES the repo's `.env` (Step 4.5). It MUST NEVER touch the maintree `.env`, because you run day-job work against the maintree and the backup/restore dance is unsafe across overlapping sessions.

```bash
MAINTREE="{{CODEBASE_ROOT}}/$REPO_NAME"
REPO_DIR="${WORKTREE:-}"

# Auto-detect: if invoked from inside {{STATE_ROOT}}/worktrees/<TICKET>/, infer
# the repo's worktree from siblings unless explicitly overridden.
if [ -z "$REPO_DIR" ]; then
  PWD_REAL="$(pwd -P)"
  case "$PWD_REAL" in
    {{STATE_ROOT}}/worktrees/*|/private{{STATE_ROOT}}/worktrees/*)
      TICKET_DIR="$(echo "$PWD_REAL" | sed -E 's|^(/private)?({{STATE_ROOT}}/worktrees/[^/]+).*|\2|')"
      [ -d "$TICKET_DIR/$REPO_NAME" ] && REPO_DIR="$TICKET_DIR/$REPO_NAME"
      ;;
  esac
fi

# Allow explicit maintree fallback ONLY when the caller opts in.
if [ -z "$REPO_DIR" ]; then
  if [ "${ALLOW_MAINTREE:-0}" = "1" ]; then REPO_DIR="$MAINTREE"
  else echo "❌ refusing to use the maintree (Step 4.5 would rewrite its .env). Pass --worktree <path> or set ALLOW_MAINTREE=1."; exit 1; fi
fi

if [ "${ALLOW_MAINTREE:-0}" != "1" ] && [ "$(cd "$REPO_DIR" && pwd -P)" = "$MAINTREE" ]; then
  echo "❌ Step 4.5 .env rewrite would land in the maintree at $REPO_DIR. Aborting."
  exit 1
fi
echo "Using repo dir: $REPO_DIR (maintree=$([ "${ALLOW_MAINTREE:-0}" = 1 ] && echo allowed || echo forbidden))"
```

**Hard rules:**
- Every later step uses `$REPO_DIR`, never the maintree path.
- Venvs / `node_modules` are sourced from wherever the repo provides them; only the `.env` mutation is worktree-scoped.
- Maintree use requires explicit `--allow-maintree` (you handle the `.env` restore yourself).

### Step 1 — Preflight + pick a port

```bash
# DB server reachable?
psql -U {{LOCAL_DB_USER}} -d postgres -c "SELECT 1" > /dev/null 2>&1 \
  || { echo "❌ Postgres not reachable. Start your local Postgres and retry."; exit 1; }

# Port detection + deterministic fallback (no mid-run prompting).
pick_port() {
  local candidate
  for candidate in "$@"; do
    lsof -tiTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1 || { echo "$candidate"; return 0; }
    echo "⚠  port $candidate busy — trying next" >&2
  done
  echo "❌ no free port in candidate list" >&2; return 1
}

SERVICE_PORT=$(pick_port "${REPO_PORT:-8000}" 18000 18001 18002) || exit 1
SERVICE_URL="http://127.0.0.1:${SERVICE_PORT}"

# Shared contract so /qe2etest, /qmanualt, curl smoke checks all hit the same port.
cat > /tmp/{{COMPANY_SLUG}}-ports.env <<EOF
# Written by /qspinuplocal — source via: set -a; . /tmp/{{COMPANY_SLUG}}-ports.env; set +a
export {{ENV_SERVICE_URL_KEY}}=${SERVICE_URL}
export SERVICE_PORT=${SERVICE_PORT}
export SERVICE_HEALTH=${SERVICE_URL}/health
EOF
echo "→ ${REPO_NAME} on ${SERVICE_URL}  (saved to /tmp/{{COMPANY_SLUG}}-ports.env)"
```

### Step 2 — (optional) Re-clone / reset the local DB

Only if your project ships a local-DB bootstrap (e.g. `/qlocalclonedb`). Skip otherwise. Don't wipe local data the user may care about — ask first.

### Step 3 — Verify the DB is usable

```bash
PSQL="psql -U {{LOCAL_DB_USER}} -d $DB_NAME"
$PSQL -c "SELECT 1" >/dev/null 2>&1 || { echo "❌ cannot connect to $DB_NAME"; exit 1; }
# Multi-tenant apps: sanity-check the registry has rows.
$PSQL -tAc "SELECT COUNT(*) FROM app.account_registry" 2>/dev/null || true
```

### Step 4 — Apply pending migrations (only if this repo has migrations)

```bash
HAS_MIGRATIONS="$(jq -r '(.[] | select(.is_primary==true) | .has_migrations) // false' "$SKILLS_ROOT/qship/repos.json")"
if [ "$HAS_MIGRATIONS" = "true" ]; then
  cd "$REPO_DIR"
  LOCAL_DB="postgresql://{{LOCAL_DB_USER}}@localhost:5432/$DB_NAME"
  # Adapt to your migration tool (alembic shown):
  DATABASE_URL="$LOCAL_DB" ./venv/bin/alembic upgrade head || echo "⚠  migration step failed — inspect before starting"
fi
```

### Step 4.5 — Point the repo's `.env` at the local DB (MANDATORY for Python apps using `load_dotenv(override=True)`)

> **The footgun this step exists for:** if your service calls `load_dotenv(override=True)` at import time, it CLOBBERS any `DATABASE_URL` you export on the command line with whatever is written in `.env`. Exporting env vars to `nohup uvicorn ...` is then NOT enough — the running process silently uses the stale `.env` DB. The only reliable fix is to rewrite `.env` itself (with a backup). If your stack reads env vars at request time (`override=False`) you can skip this, but rewriting is the safe default.

```bash
cd "$REPO_DIR"
LOCAL_DB="postgresql://{{LOCAL_DB_USER}}@localhost:5432/$DB_NAME"

PWD_NOW="$(pwd -P)"
if [ "${ALLOW_MAINTREE:-0}" != "1" ] && [ "$PWD_NOW" = "$MAINTREE" ]; then
  echo "❌ refusing to rewrite maintree .env at $PWD_NOW"; exit 1
fi

SPINUP_TS=$(date +%s)
BACKUP=".env.backup-spinup-$SPINUP_TS"
[ -f .env ] && cp .env "$BACKUP" && echo "Backed up .env -> $PWD_NOW/$BACKUP"

# Rewrite the DB-pointing keys that exist; add the critical ones if missing.
# Preserves all other keys (API tokens, auth provider config, etc.).
for key in DATABASE_URL GLOBAL_DATABASE_URL ENFORCE_DEV_DATABASE_URL; do
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i.tmp "s|^${key}=.*|${key}=$LOCAL_DB|" .env
  fi
done
# ENFORCE_DEV_DATABASE_URL short-circuits per-tenant DB routing in multi-tenant
# apps — add it even if absent so the session lands in the local DB.
grep -q '^ENFORCE_DEV_DATABASE_URL=' .env 2>/dev/null || echo "ENFORCE_DEV_DATABASE_URL=$LOCAL_DB" >> .env
[ -n "${TENANT_UUID:-}" ] && { grep -q '^DEV_TENANT_ID=' .env && sed -i.tmp "s|^DEV_TENANT_ID=.*|DEV_TENANT_ID=$TENANT_UUID|" .env || echo "DEV_TENANT_ID=$TENANT_UUID" >> .env; }
# Make any in-repo base-URL point at the port we actually bound.
if grep -q "^{{ENV_SERVICE_URL_KEY}}=" .env 2>/dev/null; then
  sed -i.tmp "s|^{{ENV_SERVICE_URL_KEY}}=.*|{{ENV_SERVICE_URL_KEY}}=$SERVICE_URL|" .env
fi
rm -f .env.tmp
echo "Rewrote .env DB pointers -> $DB_NAME"
```

Restore when done: `cp "$BACKUP" .env` in `$REPO_DIR`. Surface the backup path in the final report.

### Step 5 — Start the service

Use the project's start command. Detect a sensible default, or take `--start-cmd`:

```bash
cd "$REPO_DIR"
START_CMD="${START_CMD:-}"
if [ -z "$START_CMD" ]; then
  # Best-effort defaults — adapt to your stack.
  if [ -f manage.py ]; then START_CMD="./venv/bin/python manage.py runserver 127.0.0.1:$SERVICE_PORT"
  elif [ -f package.json ] && grep -q '"dev"' package.json; then START_CMD="npm run dev -- --port $SERVICE_PORT"
  elif ls ./venv/bin/uvicorn >/dev/null 2>&1; then START_CMD="./venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $SERVICE_PORT"
  else echo "❌ could not detect a start command — pass --start-cmd \"<cmd>\""; exit 1; fi
fi

# Detach safely so the tool call returns (close all stdio; see qship Bash-tool hang rules).
DATABASE_URL="postgresql://{{LOCAL_DB_USER}}@localhost:5432/$DB_NAME" \
  nohup $START_CMD > /tmp/{{COMPANY_SLUG}}-service.log 2>&1 </dev/null &
echo "Started: $START_CMD (pid $!, log /tmp/{{COMPANY_SLUG}}-service.log)"
```

If your stack has a worker and `--worker` was passed, start it the same way against the same `DATABASE_URL`.

### Step 6 — Health check

```bash
for i in $(seq 1 20); do
  if curl -fsS "$SERVICE_URL/health" >/dev/null 2>&1; then echo "✅ $REPO_NAME healthy on $SERVICE_URL"; break; fi
  sleep 1
  [ "$i" = 20 ] && { echo "❌ service did not become healthy — tail /tmp/{{COMPANY_SLUG}}-service.log"; tail -30 /tmp/{{COMPANY_SLUG}}-service.log; exit 1; }
done
```

### Step 7 — Report

Print: the repo + worktree used, the bound port / URL, the DB name, the `.env` backup path, and the log path. If `/qe2etest` or `/qmanualt` will run next, remind the caller to `source /tmp/{{COMPANY_SLUG}}-ports.env` so they hit the same port.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Service uses the wrong DB despite exported env | `load_dotenv(override=True)` clobbered your export at import | Step 4.5 rewrites `.env` — confirm it ran against `$REPO_DIR`, not the maintree |
| `Connection refused` on a base-URL the UI calls | stale URL in `.env` | Step 4.5 rewrites `{{ENV_SERVICE_URL_KEY}}` to the bound port |
| Port already in use | another stack / IDE / Docker holds it | the fallback ladder picks 18000+; the real port is in `/tmp/{{COMPANY_SLUG}}-ports.env` |
| Multi-tenant 403 "no access to organization" | session landed in the wrong DB | ensure `ENFORCE_DEV_DATABASE_URL` and `DEV_TENANT_ID` were written in Step 4.5 |

## Cleanup

```bash
lsof -ti:"${SERVICE_PORT:-8000}" | xargs -r kill -9
# restore the repo's .env from the Step 4.5 backup
```
