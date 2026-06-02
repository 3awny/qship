# Customizing qship for your codebase

qship ships intentionally generic. Everything company-specific is a
`{{PLACEHOLDER}}` resolved at install time from your answers. This doc explains
what each knob does and how to adapt the skills to your stack.

## The model

`setup.sh` (or `/qship:configure`) renders every template under `templates/`
through `envsubst`, replacing `{{VAR}}` tokens with your values and writing the
result into `~/.claude/skills/`. Nothing company-specific lives in the repo.

The full **21-skill pipeline** installs every time — there are no skill-selection
toggles. Every skill is reachable from the `qship`/`qshipmaster` pipeline, so the
only thing you configure is *values* (identity, repos, tracker, DB), not *which
skills*.

## Identity knobs (the questionnaire)

| Placeholder | Example | Used for |
|---|---|---|
| `{{COMPANY_SLUG}}` | `acme` | tmp paths, DB-name defaults, log prefixes |
| `{{COMPANY_SLUG_UPPER}}` | `ACME` | env-var prefixes |
| `{{CODEBASE_ROOT}}` | `/Users/you/work` | where your repos live |
| `{{CODEBASE_DIR_NAME}}` | `work` | the dir-name of the codebase root |
| `{{CODEBASE_PATH_PREFIX}}` | `src` | top-level source dir inside each repo |
| `{{PRIMARY_REPO_NAME}}` | `my-app` | the main repo skills default to |
| `{{JIRA_PROJECT_KEY}}` | `PROJ` | ticket-key prefix in branch names / examples |
| `{{GH_ORG}}` | `acme-inc` | GitHub org for `gh pr create` |
| `{{STATE_ROOT}}` | `/tmp/acme-qship` | where qship writes pipeline state |
| `{{LOCAL_DEV_DB_NAME}}` | `local_acme_db` | local Postgres DB name |
| `{{LOCAL_DB_USER}}` | `postgres` | local Postgres role |
| `{{DB_OWNER_ROLE}}` | `postgres` | DB owner for grant statements |

## Repos — declare each one

| Field | What it does |
|---|---|
| `name` | Repo display name; resolves `{{PRIMARY_REPO_NAME}}` |
| `kind` | `monolith` / `service` / `library` / `gateway` / `frontend` / `worker` / `test-harness` |
| `has_migrations: true` | `qmigrationdevcheck` iterates only over flagged repos |
| `runs_locally: true` | `qspinuplocal` starts only flagged repos |
| `is_primary: true` | The "main" repo for skills that need a single default |
| `schema` | Postgres schema the repo owns (for migration checks) |
| `port` | Local dev port (for spin-up + E2E) |

`repos[]` is an array — declare 1 repo or 100. The pipeline skills that are
repo-shape-aware (`qmigrationdevcheck`, `qshipmaster`, `qspinuplocal`,
`qe2etest`) read `repos.json` at runtime and iterate over the flagged repos.

## Issue tracker — Jira or none

| `tracker_type` | Behaviour |
|---|---|
| `jira` | Ticket-driven skills fetch + transition tickets via the Atlassian MCP. Needs `jira_project_key` + optional `atlassian_cloud_id`. |
| `none` | Tracker-agnostic. Skills take a pasted ticket / local file; no MCP calls. |

`linear` / `github` are reserved for future adapters (accepted, treated as
`none` today). Adding a real adapter is a documented ~4-file change — see the
single source of truth at `templates/skills/qship/references/tracker-contract.md`
and [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

Switching later: re-run `/qship:configure` (or `bash setup.sh --config
answers/last-run.json`) and re-render.

## The 21 skills

All install unconditionally. The ones that are stack-specific simply **no-op or
skip** when your diff doesn't touch their surface:

- **Pipeline + gates:** `qship`, `qshipmaster`, `qshipcheck`, `qshipphasecheck`
- **Build:** `qplan`, `qdirectory`, `qclean`, `qreuse`
- **Review:** `qcheck`, `qcheckt`, `qcheckf`, `qcomponent`, `qbug`, `qbcheck`
- **Accept + memory:** `qe2etest`, `qmanualt`, `qspinuplocal`, `qlocalclonedb`, `qmemory`
- **Stack checks (fire only when the diff needs them):** `qmigrationdevcheck`
  (Alembic migrations — gated on `alembic/versions/*` changes via `has_migrations`
  repos), `qauthtrailingslash` (FastAPI route / trailing-slash changes)

## Adapting skills to your stack

The rendered skills in `~/.claude/skills/` are yours to edit. Common changes:

- **Different test command** — skills call `pytest`; swap for your runner.
- **Different migration tool** — `qmigrationdevcheck` assumes Alembic; adapt or
  let it no-op (it only fires on `alembic/versions/*` diffs).
- **No local stack** — `qe2etest` calls `qspinuplocal` to boot your primary
  service; point `qspinuplocal` at your start command, or run E2E against a
  shared env and record the evidence manually.
- **Single shared DB / single-tenant** — multi-tenant guidance in the review and
  E2E skills is written conditionally ("*if the app is multi-tenant*"), so it
  simply doesn't apply; nothing to strip.
- **Multi-repo** — list every repo in `repos[]`; the repo-aware skills operate
  across all flagged repos.
- **Codex** — set `provider=codex` / `reviewer=codex` on `/qship`. See
  [`CODEX.md`](CODEX.md).
- **Postgres connection** — set DB host/port/name/role in the questionnaire.

## Pre-flight: required external plugins

The pipeline delegates review / bug-hunt / simplify steps to official Anthropic
plugins. `bash setup.sh --check` flags any that are missing (the #1 cause of a
failed first run). See the README's "Companion plugins" section for the install
commands.
