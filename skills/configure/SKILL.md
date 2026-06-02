---
name: configure
description: One-time interactive configurator for the qship skill catalog. Run this immediately after installing the qship plugin (the SessionStart hook will remind you on first use). Walks through a short questionnaire (7 rounds, ~two dozen questions) plus a per-repo loop (1 repo or 100, the configurator doesn't care), renders the full skill set into your ~/.claude/skills/ tree, then verifies the install and required external plugins. Idempotent — re-runnable any time you want to change a value (added a service, new Jira project key, opted into a previously-skipped integration).
---

# qship — interactive configurator

This skill is the **bootstrap step** for the qship plugin. The plugin ships templates; this skill collects the values that fill them in.

## When to run

- **First time you install the qship plugin** — the SessionStart hook prints a prompt directing you here.
- **Whenever you want to change a configured value** — added a service, new Jira project key, opted into a previously-skipped integration (Alembic migrations, ngrok, Playwright). Re-running re-renders the whole catalog from the latest answers.

## What it does, end-to-end

1. **Loads previous answers** from `$CLAUDE_PLUGIN_ROOT/answers/last-run.json` if present.
2. **Asks the questionnaire (7 rounds, ~two dozen questions) plus a per-repo loop** via the `AskUserQuestion` tool. Defaults pulled from `$HOME`, `git config`, `$USER`, and platform conventions wherever possible.
3. **Writes the consolidated answers** to `$CLAUDE_PLUGIN_ROOT/answers/last-run.json`.
4. **Shells out to `setup.sh --config <answers-file>`** to render templates via `envsubst`, write `repos.json` to the skill root, merge hooks into `~/.claude/settings.json`, and touch the first-run marker.
5. **Verifies the install** via `setup.sh --check` and surfaces any missing external plugins to the user.
6. **Prints a quickstart** with example invocations.

## Step-by-step

### Step 1 — Load previous answers, if any

```bash
ANSWERS_FILE="$CLAUDE_PLUGIN_ROOT/answers/last-run.json"
mkdir -p "$(dirname "$ANSWERS_FILE")"
if [ -f "$ANSWERS_FILE" ]; then
  echo "[/qship:configure] Loaded previous answers from $ANSWERS_FILE."
fi
```

Use the values from `$ANSWERS_FILE` as the per-question default in the next step.

### Step 2 — Auto-detect what you can

```bash
USER_HOME="${USER_HOME:-$HOME}"
SKILLS_ROOT="${SKILLS_ROOT:-$HOME/.claude/skills}"
LOCAL_DB_USER_DEFAULT="${LOCAL_DB_USER:-$USER}"
GH_HOST_DEFAULT="${GH_HOST:-github.com}"
DEFAULT_BRANCH_DEFAULT="${DEFAULT_BRANCH:-develop}"
PRIMARY_LANGUAGE_DEFAULT="${PRIMARY_LANGUAGE:-python}"
CODEBASE_ROOT_DEFAULT="${CODEBASE_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/work/your-monorepo")}"
```

### Step 3 — Ask the questionnaire (6 rounds)

> qship installs the full **21-skill pipeline** every time — there are no
> skill-selection rounds. You only collect *values* (identity, repos, tracker,
> DB), never *which skills*.

**Round 1 — Project identity + issue tracker** (4 questions):
- Company / project short slug — default `acme`.
- **Issue tracker** — `jira` or `none` (default `jira`). `jira` uses the Atlassian MCP to fetch/create/transition tickets and read Confluence TRDs. `none` means **no tracker MCP**: you paste a ticket/TRD as text or pass a local markdown-file path, and the ticket-driven skills skip every Atlassian call. (`linear`/`github` are accepted but currently treated as `none` — no provider integration ships yet.) **Sets `tracker.tracker_type`.**
- Ticket-key prefix — default `PROJ`. Used in ticket IDs / branch names / examples (e.g. `PROJ`, `TASK`, `ABC`). Stored as `tracker.jira_project_key` for placeholder back-compat; applies to any tracker.
- GitHub host — default `github.com`. (You can fold GitHub host + org into this round; the configurator may ask them here or in a follow-up — keep total ≤4 per AskUserQuestion call.)

> When `tracker_type` is not `jira`, **skip the Atlassian cloudId question** in the later rounds (it's Jira-only) — mirror what `setup.sh` does.

**Round 2 — Codebase paths + GitHub org** (4 questions):
- GitHub org name — default `your-org`.
- Absolute path to monorepo root — default `$CODEBASE_ROOT_DEFAULT`.
- Top-level source directory inside each repo (e.g. `src/`, `app/`, `packages/`) — default `src`.
- Default base branch — default `$DEFAULT_BRANCH_DEFAULT`.
- State root for transient qship files — default `/tmp/<slug>-qship`.

**Round 3 — Language + tooling** (4 questions):
- Primary language — `python` / `typescript` / `go` / `mixed` (default `python`).
- Test command — language-specific default.
- Lint command — language-specific default.
- Format command — language-specific default.

**Round 4 — Build the flexible repos[] list** (per-repo loop — do this BEFORE the opt-in rounds):

Drop ALL assumptions about how the user's codebase is organised — single repo, 2-repo split, 12-service monorepo are all valid. Loop with `AskUserQuestion` until the user signals "done". For each repo capture:

| Field | Description | Default |
|---|---|---|
| `name` | Directory name relative to `codebase_root` (or absolute path) | (required) |
| `kind` | Hint: monolith / service / library / gateway / frontend / worker / test-harness / other | `service` |
| `schema` | SQL schema this repo owns (null if N/A) | `null` |
| `package` | Python/JS package name for imports inside this repo | `null` |
| `has_migrations` | Set true if this repo has Alembic migrations — `qmigrationdevcheck` iterates only over flagged repos | `false` |
| `runs_locally` | Set true if `qspinuplocal` should start this repo's process for E2E | `false` |
| `is_primary` | The "main" repo for skills that need ONE default | `true` on first repo, else `false` |
| `port` | Default local dev port (integer or null) | `null` |

Flow: (1) ask "How many repos?" (`1` / `2-3` / `4+` / Other); (2) for each repo, grouped `AskUserQuestion` calls for name/kind/schema-package/flags+port; (3) "Add another repo?" yes/no. Single-repo users accept one entry and move on — everything MUST work with `repos.length == 1`.

**Round 5 — Local DB** (4 questions — used by `qspinuplocal` / `qe2etest` / `qmigrationdevcheck`):
- Local Postgres role — default `$LOCAL_DB_USER_DEFAULT`.
- Local Postgres host — default `localhost`.
- Local Postgres port — default `5432`.
- Default local dev DB name — default `dev_db`.

**Round 6 — Codex integration** (1 question):
- Wire skills into `~/.codex/skills/` as well as `~/.claude/skills/`? — defaults `y` if `codex` is on PATH. (This is the only install flag; the 21-skill pipeline installs unconditionally.)

### Step 4 — Compute derived values

```bash
COMPANY_SLUG_LOWER="$(echo "$COMPANY_SLUG" | tr '[:upper:]' '[:lower:]')"
COMPANY_SLUG_UPPER="$(echo "$COMPANY_SLUG" | tr '[:lower:]' '[:upper:]')"
CODEBASE_DIR_NAME="$(basename "$CODEBASE_ROOT")"
[ -z "${STATE_ROOT:-}" ] && STATE_ROOT="/tmp/${COMPANY_SLUG_LOWER}-qship"

# Env-var key names
ENV_SERVICE_URL_KEY="${ENV_SERVICE_URL_KEY:-SERVICE_URL}"
ENV_CLOUD_URL_KEY="${ENV_CLOUD_URL_KEY:-CLOUD_URL}"
ENV_OAUTH_CLIENT_ID_KEY="${ENV_OAUTH_CLIENT_ID_KEY:-OAUTH_CLIENT_ID}"
ENV_OAUTH_CLIENT_SECRET_KEY="${ENV_OAUTH_CLIENT_SECRET_KEY:-OAUTH_CLIENT_SECRET}"
DB_OWNER_ROLE="${DB_OWNER_ROLE:-app_admin}"
```

### Step 5 — Write the answers file

Use the `Write` tool to emit `answers/last-run.json` matching `config.example.json` exactly. The `repos` field is the array you built in Round 4. Booleans under `features` are JSON `true`/`false`.

### Step 6 — Run setup.sh non-interactively

```bash
bash "$CLAUDE_PLUGIN_ROOT/setup.sh" --config "$CLAUDE_PLUGIN_ROOT/answers/last-run.json"
```

This renders templates with the user's `{{PRIMARY_REPO_NAME}}` resolved, writes `repos.json` to `$SKILLS_ROOT/qship/repos.json`, merges hooks, and touches the first-run marker.

### Step 7 — Verify the install + required external plugins (CRITICAL)

`setup.sh` already prints any MISSING external plugins. Run the self-check and surface the result to the user explicitly — this is the #1 cause of a first `/qship` run failing mid-pipeline:

```bash
bash "$CLAUDE_PLUGIN_ROOT/setup.sh" --check
```

If it reports missing plugins (`superpowers`, `feature-dev`, `code-review`, `code-simplifier`, `pr-review-toolkit`), DO NOT tell the user setup is complete. Show them the exact `/plugin marketplace add … && /plugin install …` lines and explain that qship's review/bug-hunt/simplify steps delegate to those plugins and will fail without them. Only declare success once `--check` exits 0 (or the user has acknowledged the missing-plugin list).

### Step 8 — Print the quickstart

Show the user the example invocations + links to `docs/CUSTOMIZING.md` and `docs/CODEX.md`. Mention they can re-run `/qship:configure` any time to add a repo or change a value, and `bash setup.sh --check` any time to re-verify health.

## How skills read the repos config at runtime

Multi-repo aware skills (qmigrationdevcheck, qshipmaster, qspinuplocal, qlocalclonedb) read `$SKILLS_ROOT/qship/repos.json` directly. Examples:

```bash
# Iterate every repo that has migrations
jq -r '.[] | select(.has_migrations==true) | .name' "$SKILLS_ROOT/qship/repos.json" \
  | while read repo; do
      cd "$CODEBASE_ROOT/$repo"
      alembic check
    done

# Resolve the primary repo
PRIMARY="$(jq -r '(.[] | select(.is_primary==true) | .name) // .[0].name' "$SKILLS_ROOT/qship/repos.json")"

# Get a repo by name
jq -r --arg n "$1" '.[] | select(.name==$n)' "$SKILLS_ROOT/qship/repos.json"
```

Single-repo aware skills (qcheck, qclean, qbug, qpr, etc.) operate on `$(git rev-parse --show-toplevel)` — no repos.json lookup needed.

## Sanity checks

- `$CLAUDE_PLUGIN_ROOT` must be set.
- `jq` and `envsubst` must be on `PATH`.
- `$HOME/.claude/` must exist.
- The repos[] array must have at least one entry.
- Exactly ONE repo should be flagged `is_primary: true` (the configurator enforces this — defaults the first entry).

## Notes for re-runs

Re-running this skill is **safe**:
- `setup.sh` takes a timestamped backup of `~/.claude/settings.json` before merging.
- Re-rendering overwrites the existing `~/.claude/skills/<name>/<file>` — any local edits the user made directly to a rendered skill will be lost.
- The marker file gets re-touched.

## Don't do these things

- DO NOT skip AskUserQuestion rounds and silently re-use previous answers. The user invoked this skill because they want to change something — confirm each value.
- DO NOT edit any file under `templates/` directly — that's the maintainer-side template tree.
- DO NOT assume a specific number of repos. Single-repo, 2-repo, 12-service: all valid.
