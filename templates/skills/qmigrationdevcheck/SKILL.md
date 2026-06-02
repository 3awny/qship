---
name: qmigrationdevcheck
description: Validate an Alembic migration chain before it ships — checks for multiple heads, broken/cyclic down-revisions, divergent branches, and migrations that won't apply cleanly on top of the base branch. Use when a change adds or edits files under `alembic/versions/`; qship runs it automatically when the diff touches migrations.
---

# Alembic Migration Chain Validator

You are validating that Alembic migrations on the current branch are compatible with `develop` — no multiple heads now, no multi-head after merge, no chain breaks, no {{COMPANY_SLUG}}-specific violations.

> **Multi-repo contract:** This skill operates on the repos in `$SKILLS_ROOT/qship/repos.json` whose `has_migrations` flag is `true`. Single-repo users with one alembic chain get a degenerate-but-correct check (one repo in the iteration). Multi-repo users get full cross-schema validation. Resolve the list at the start of every invocation:
>
> ```bash
> REPOS_WITH_MIGRATIONS=$(jq -r '.[] | select(.has_migrations==true) | .name' "$SKILLS_ROOT/qship/repos.json")
> ```

**Input:** `$ARGUMENTS` may contain:
- A specific repo name (must match one of the `has_migrations==true` entries) or `all` (default — every flagged repo)
- A caller flag: `mode=qshipp2` (report-only) or `mode=user` (apply fixes, default)

Examples:
- `/qmigrationdevcheck` → default user mode, all repos with `has_migrations==true`, applies fixes interactively
- `/qmigrationdevcheck <repo>` → user mode, just that repo (must be flagged for migrations)
- `/qmigrationdevcheck mode=qshipp2 <repo>` → invoked by /qshipp2; REPORT ONLY, do not apply fixes

## Mode Semantics — READ FIRST

The caller mode fundamentally changes behaviour:

| Mode | Detection | Fix application | Output |
|---|---|---|---|
| `user` (default) | Runs all checks | Applies fixes interactively — confirms before risky changes | Report + applied changes summary |
| `qshipp2` | Runs all checks | **NEVER applies fixes.** Report-only. | Report structured for the caller to post as a PR comment |

**In `qshipp2` mode, skip Step 8 entirely.** The orchestrator decides what to do with findings (post PR comment, block the pipeline, etc.).

**In `user` mode, Step 8 is mandatory after any FAIL** — detect-and-describe-without-fixing is not the point of the direct invocation.

Parse mode AND repo selector from `$ARGUMENTS`:

```bash
MODE="user"
REPO="all"
for tok in $ARGUMENTS; do
  case "$tok" in
    mode=qshipp2) MODE="qshipp2" ;;
    mode=user)    MODE="user" ;;
    all) REPO="all" ;;
    *) if jq -e --arg n "$tok" '.[] | select(.name==$n and .has_migrations==true)' "$SKILLS_ROOT/qship/repos.json" >/dev/null 2>&1; then REPO="$tok"; fi ;;
  esac
done
```

If `REPO != all`, restrict every subsequent step to that repo's directory. If unset, scan all repos that contain an `alembic/` directory.

## Protocol

### Step 1: Identify Migration Repos

Resolve the repos to check from config — every entry flagged `has_migrations==true`:

```bash
for repo in $(jq -r '.[] | select(.has_migrations==true) | .name' "$SKILLS_ROOT/qship/repos.json"); do
  [ -d "{{CODEBASE_ROOT}}/$repo/alembic" ] && echo "will check: $repo"
done
```

If `$ARGUMENTS` named a specific repo (and it's in the `has_migrations` set), check only that one.

### Step 2: Skip if No Migration Changes

```bash
git fetch origin develop --quiet
git diff --name-only origin/develop..HEAD -- alembic/versions/ | head -5
```

If empty → stop, report "No migration changes on this branch — nothing to check".

### Step 3: Check Current Branch Heads

```bash
cd <repo>
alembic heads
```

**Expected:** Single head. If multiple heads → **FAIL (Check 3a)**.

### Step 4: Compare with Develop

```bash
# Migrations only on our branch (new)
git ls-tree -r origin/develop -- alembic/versions/ | awk '{print $4}' | sort -u > /tmp/develop_migrations.txt
git ls-tree -r HEAD              -- alembic/versions/ | awk '{print $4}' | sort -u > /tmp/head_migrations.txt
comm -23 /tmp/head_migrations.txt /tmp/develop_migrations.txt  # our-branch-only

# Migrations added to develop since branch-point (indicate possible conflict)
git log origin/develop --not HEAD --oneline -- alembic/versions/
```

For each branch-only migration file, read its `down_revision`. Run:

```bash
grep -E "^(revision|down_revision)" <migration_file>
```

### Step 5: Detect Conflicts

Run **every check**. Don't stop at the first failure — accumulate issues for the final report.

**Check 3a — Multiple heads right now**

Two migrations share the same `down_revision`. Caught by `alembic heads` in Step 3.

**Check 3b — Missing parent**

A migration references a `down_revision` revision_id that doesn't exist in the tree. Caught by `alembic check`.

**Check 3c — Duplicate revision IDs**

Two files with the same revision hash. Caught by `alembic check`.

**Check 3d — Multi-head forecast after merge**

Another PR has landed a migration on `develop` since you branched. If our new migration's `down_revision` equals a revision that is no longer develop's head, merging creates multi-head immediately.

```bash
# Compare the down_revision of our earliest new migration against develop's current head
DEVELOP_HEAD=$(git show origin/develop:alembic/versions/ 2>/dev/null ; \
               # or: run `alembic heads` against a checkout of develop)
```

Detection (runnable):

```bash
# Develop's head revision ID (from a fresh worktree, no checkout needed)
DEVELOP_HEAD=$(git fetch origin develop --quiet && \
  git -c advice.detachedHead=false worktree add -q /tmp/qmdc-develop origin/develop 2>/dev/null && \
  ( cd /tmp/qmdc-develop && alembic heads 2>/dev/null | awk '{print $1}' | head -1 ) ; \
  git worktree remove --force /tmp/qmdc-develop >/dev/null 2>&1)

# Our earliest new migration's down_revision
OUR_PARENT=$(grep -E "^down_revision\s*=" $(comm -23 /tmp/head_migrations.txt /tmp/develop_migrations.txt | head -1) \
  | sed -E "s/.*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")

[ "$OUR_PARENT" != "$DEVELOP_HEAD" ] && echo "FAIL 3d: parent=$OUR_PARENT develop=$DEVELOP_HEAD"
```

If our parent ≠ develop head → **FAIL** — need rebase or empty merge migration.

**Check 3e — Cross-schema FK (only when you have 2+ schemas)**

If your repos own separate Postgres schemas (each repo's `schema` field in `repos.json`), a migration in one repo must NOT create a foreign key into another repo's schema — the referenced tables may not exist when that repo's migrations run (CI typically runs `--schema all` in dependency order). Use a plain `UUID` column + application-layer integrity instead.

```bash
# For each other repo's schema, flag cross-schema FKs in this repo's new migrations:
OTHER_SCHEMAS=$(jq -r '.[] | select(.schema != null) | .schema' "$SKILLS_ROOT/qship/repos.json")
for s in $OTHER_SCHEMAS; do
  grep -E "ForeignKey\(['\"]$s\.|referent_schema=['\"]$s" alembic/versions/*.py
done
```

If any match on branch-new files → **FAIL**. (Single-schema projects: this check is a no-op.)

**Check 3f — Merge migration hygiene**

Per CLAUDE.md: merge migrations (those with `down_revision = (rev1, rev2, ...)`) must be **empty** — `pass` in both `upgrade()` and `downgrade()`. Schema changes go in a separate migration that depends on the merge.

For any branch-new migration whose `down_revision` is a tuple, open the file:
- `upgrade()` body must be `pass` (plus comments)
- `downgrade()` body must be `pass`
- No `op.*` calls anywhere

If violated → **FAIL**.

**Check 3g — Cross-repo migration ordering (only when 2+ repos have migrations)**

If two of your repos both have new migrations on their feature branches and one depends on the other (e.g. a downstream service references a table a shared library just added), check that the dependent repo's migration doesn't reference tables/columns the depended-on repo only just introduced — unless that migration is already merged to develop.

```bash
# In the depended-on repo's branch migrations, list newly added tables:
grep -E "op\.(add_column|create_table)\s*\(['\"]" <depended-on repo's branch migrations>
# Then grep the dependent repo's branch migrations for those table names.
```

If found → warn: **the depended-on repo must merge and deploy first**. Document the merge order in both PR descriptions. (Single-repo projects: no-op.)

**Check 3h — Untrimmed autogen boilerplate (advisory)**

Smoking gun that drift wasn't reviewed:

```bash
grep -l "# ### commands auto generated by Alembic - please adjust" alembic/versions/<branch-new>
```

Not always a real problem but prompts the reviewer to verify the migration was actually trimmed to PR scope.

**Check 3i — Orphaned tenant stamps (post-merge CI risk)**

Prevents `run_all_migrations.py` from failing on CI because a tenant's `alembic_version` points to a revision that no longer exists on disk. Two recurring root causes — deleted-merge consolidation, or a feature-branch migration that was run against staging then never merged.

**Detection (read-only):** for each active row in `app.account_registry`, connect via `AccountRegistry` + `DBProviderClient.build_connection_string(..., pooled=True)` (do NOT re-implement) and read `<schema>.alembic_version` for each schema your `has_migrations` repos own (the `schema` field in `repos.json`). FAIL any (tenant, schema, revision) where revision is not resolvable in `alembic history` on the current branch.

Use the bundled scanner — it implements exactly the contract above so you don't re-derive it:

```bash
# From any cwd. Run with the {{PRIMARY_REPO_NAME}} venv (has alembic + sqlalchemy + dotenv installed).
<core-root>/venv/bin/python \
  ~/.claude/commands/qmigrationdevcheck/scripts/scan_orphan_tenants.py \
  --core-root <abs-path>/{{PRIMARY_REPO_NAME}} \
  --{{PRIMARY_REPO_NAME}}-root <abs-path>/{{PRIMARY_REPO_NAME}}
```

Output is a tenant×schema list with any orphan revisions, plus a summary line `Tenants scanned / Orphan stamps / Skipped tenants`. Exit code 0 = all clean, 1 = orphan(s) found, 2 = operator error (missing env / wrong paths).

**How it picks the env:**

1. Loads `<core-root>/.env` (typically has `DB_PROVIDER_API_KEY`).
2. Loads `<core-root>/.env.staging` with `override=True` (typically has the **staging** `GLOBAL_DATABASE_URL`). Staging takes precedence so the scan walks the multi-tenant staging registry, not your single-tenant local DB.

If `.env.staging` is missing AND `GLOBAL_DATABASE_URL` points at a single-tenant local DB (no `account_registry` table), the scanner will fail with a clear error — that's the intended signal that you don't have the credentials for this check on this host.

**Env prereq:** `GLOBAL_DATABASE_URL` (staging), `DB_PROVIDER_API_KEY`, optional `DATABASE_OWNER` (default `{{DB_OWNER_ROLE}}`). If either {{PRIMARY_REPO_NAME}} env is missing, emit WARN/SKIPPED — never crash the report.

For root-cause classification and the fix, jump to **Resolution Playbook → Orphaned tenant stamps**.

### Step 6: Validate Chain Integrity

```bash
# Full chain validation
alembic history --verbose 2>&1 | head -30

# Modern alembic check (catches unapplied autogen drift)
alembic check 2>&1
```

### Step 7: Report

```
## Migration Chain Check: <repo>

Status: PASS / FAIL / WARN

### Heads
- Current branch: <revision_id> (<description>)
- Origin develop:  <revision_id> (<description>)
- Multiple heads now: YES/NO
- Multi-head after merge: YES/NO

### Chain
- Total migrations:   N
- Our branch adds:    N new migrations
- Develop added since branch-point: N migrations

### Check Results
  3a Multiple heads now            [PASS/FAIL]
  3b Missing parent                [PASS/FAIL]
  3c Duplicate revision IDs        [PASS/FAIL]
  3d Multi-head after merge        [PASS/FAIL]
  3e Cross-schema FK ({{PRIMARY_REPO_NAME}})    [PASS/FAIL/N/A]
  3f Merge migration hygiene       [PASS/FAIL/N/A]
  3g Core→{{PRIMARY_REPO_NAME}} ordering        [PASS/FAIL/WARN/N/A]
  3h Untrimmed autogen boilerplate [WARN/N/A]
  3i Orphaned tenant stamps        [PASS/FAIL/SKIPPED]

### Orphaned tenants (if any, 3i)
  <tenant_name>  <schema>  stamped_at=<rev>  (not resolvable on branch)

### Issues (if any)
1. [Issue description]
   Resolution: [playbook block below]
```

---

### Step 8: Apply Fixes (user mode ONLY — skip in qshipp2 mode)

**In `MODE=qshipp2`: STOP HERE.** Return the Step 7 report to the caller. Do not apply any fixes. Do not edit any files. Do not create any commits. The caller will post the report as a PR comment.

**In `MODE=user`:** For each FAILing check, apply the fix. Auto-apply the safe ones; confirm with the user for risky ones.

#### 8.1 Auto-apply (no confirmation needed)

Run these without asking. They are mechanical and reversible.

**Untrimmed autogen boilerplate (Check 3h):** skip auto-fix. Trimming requires PR-scope knowledge this skill doesn't have. Record as "manual review recommended" and continue.

#### 8.2 Confirm-then-apply (ask once, apply all)

Show the user the intended edits as a diff summary, then ask: *"Apply these fixes? (y/n)"* — **one confirmation covers all pending fixes** so the user isn't asked per file.

**Multi-head forecast after merge (Check 3d) — simple case:**

*Applies when*: exactly one new migration on branch; exactly one develop head that is not our parent.

Rebase the stale `down_revision` to develop's current head.

```bash
# Detected: our migration <REV> has down_revision=<OLD_PARENT>
# Develop head is now <DEVELOP_HEAD>
# Proposed: edit <REV>'s down_revision to <DEVELOP_HEAD>
```

After confirmation, edit the file in place, then re-run `alembic heads` to verify single head.

**Multi-head forecast after merge (Check 3d) — complex case** (more than one new migration on branch, or multiple develop heads): do NOT auto-rebase. Fall through to 8.3.

**Multiple heads currently on the branch (Check 3a):** almost always a rebase mistake. Show the conflicting migrations, recommend manual rebase via the Resolution Playbook.

**Orphaned tenant stamps (Check 3i) — stamp to nearest valid ancestor:**

This is the fix that saves `run_all_migrations.py` from exiting non-zero on CI. For each offending (tenant, schema) pair, propose a re-stamp:

```
# Detected orphans:
#   ACME Corp           {{PRIMARY_REPO_NAME}}                       stamped=aaaaaaaaaaaa (not on branch)
#   Northwind Logistics {{PRIMARY_REPO_NAME}}  stamped=deadbeefcafe (not on branch)
#
# Proposed fix (one confirmation covers all):
#   ACME Corp           {{PRIMARY_REPO_NAME}}                       -> <nearest ancestor on branch>
#   Northwind Logistics {{PRIMARY_REPO_NAME}}  -> <nearest ancestor on branch>
```

**Choosing the target revision:**

1. Prefer the **nearest ancestor on the current branch** to the orphan's original lineage — reconstruct by inspecting the orphan migration file in git history (`git log --all -- alembic/versions/<schema>/*<orphan>*.py`) and walking its `down_revision` tuple until one of the parents IS in the current branch's `alembic history`.
2. If the orphan was an **empty merge** (upgrade/downgrade bodies are `pass`) — common pattern when an old branch's merge migration carried no real DDL — any of its ancestors on the current branch is schema-equivalent. Default to **develop's head for that schema** minus this PR's new migrations (i.e., develop's head at the branch point).
3. If the orphan lives on a **feature/fix branch only** (developer applied it against staging for testing; never merged to develop) — treat it like case 1 but use `git log --all --remotes` to find the migration file, then walk back to its parent. If the migration's DDL is already on develop under a different revision ID, re-stamp to that develop revision. If the DDL is not on develop AND the tenant DB actually has the schema changes, the fix requires a code companion: either land the migration on develop first, or create a downgrade to undo the partial state before re-stamping.
4. If the orphan carried **real DDL** and the DB has the changes applied (and there is no develop-side equivalent to stamp to) — STOP and fall through to 8.3. Re-stamping loses state. The user needs to decide whether to apply the missing migration manually or abandon the tenant.

**How to apply (after a single user "y" covers the full plan):**

Use the bundled script — `qmigrationdevcheck/scripts/stamp_orphan_tenants.py`. It encapsulates the `AccountRegistry` + `DBProviderClient` lookup and the `command.stamp(..., purge=True)` call so you don't re-derive it on every invocation. Pass a JSON plan of `{tenant_name, schema, target_revision}` entries:

```bash
python ~/.claude/commands/qmigrationdevcheck/scripts/stamp_orphan_tenants.py \
  --repo-root <repo> --plan /tmp/orphan_plan.json
```

If the host blocks writes from inside the repo tree, copy the script to `/tmp/` and invoke from there — the the Postgres provider helpers resolve tenant credentials regardless of script location. After stamping, read back `SELECT version_num FROM <schema>.alembic_version` to confirm.

#### 8.3 Do not auto-apply — describe, then hand off to user

Cases that need human judgement. Output the relevant Resolution Playbook block (below), confirm with the user if they want you to proceed step-by-step, but do not edit files silently.

- **Cross-schema FK (Check 3e)** — replacement semantic; user must confirm they want plain `UUID` instead of `ForeignKey("public.xxx")`.
- **Merge migration with content (Check 3f)** — splitting into an empty merge + a follow-up requires the user to name the follow-up.
- **Missing parent / duplicate revision IDs (Check 3b/3c)** — often indicates a deeper issue (bad cherry-pick, force-push, or corrupt history). Describe, don't auto-fix.
- **Core→{{PRIMARY_REPO_NAME}} ordering (Check 3g)** — it's a coordination problem, not a code fix. Document in PR descriptions; do not auto-edit anything.
- **Complex multi-head (Check 3d)** — multiple new migrations or multiple develop heads. User chooses whether to rebase each or create an empty merge.

#### 8.4 Verify

After any fixes applied, re-run the relevant checks from Step 5 and report the delta:

```
Fixes applied:
  - <file>: down_revision <OLD> -> <NEW>
  - tenant <name> <schema>: stamp <OLD> -> <NEW>

Re-verification:
  alembic heads  -> single head ✓
  alembic check  -> no errors ✓
  tenant stamps  -> all resolvable on branch ✓ (3i)

Remaining issues: <any FAIL that wasn't auto-fixed>
```

If any check still fails, surface it and stop — do not commit partially-fixed state.

#### 8.5 Commit + push (user mode, if fixes were applied)

Only if fixes were applied AND re-verification passed. One commit per repo touched:

```bash
git add -u <changed-migration-files>
git commit -m "fix: resolve alembic migration chain issues

<bullet list of what was fixed>"
```

Do NOT push automatically — show the user the commit and ask if they want to push. Pushes to feature branches are reversible but still a broadcast action.

---

## Resolution Playbook

Emit the matching block(s) for each FAIL.

### Multi-head (now, or forecast after merge) — Check 3a/3d

Two acceptable fixes, from the Alembic docs:

**Option A — Rebase (preferred for single-developer scenarios):**

```bash
git fetch origin develop
# Identify our migration with the stale down_revision.
# Edit its down_revision to equal develop's current head.
# Run `alembic upgrade head` against the dev DB to verify linearity.
```

Linear history is easier to reason about and easier to revert. Use rebase when the team is small and the conflict is simple.

**Option B — Empty merge migration (team race, larger teams):**

```bash
alembic merge -m "merge <feature> with develop heads" heads
```

Alembic generates a migration with `down_revision = (your_head, develop_head)` and **empty upgrade/downgrade**. Per {{COMPANY_SLUG}} CLAUDE.md and Alembic docs, merges must remain empty — schema changes go in a follow-up migration depending on the merge.

### Missing parent / duplicate revision IDs — Check 3b/3c

Read `alembic check` / `alembic history --verbose` output. Usually a copy-paste mistake in `down_revision` or `revision`. Fix the offending file's ID or down_revision and re-run.

### Cross-schema FK (cross-repo, when one repo references another's schema) — Check 3e

Replace `ForeignKey("public.xxx.yyy")` with a plain `UUID` column. Reference integrity is enforced at the application layer, not the DB. See memory: `feedback_cross_schema_fk_fragile`.

### Merge migration has content — Check 3f

Split it: put the schema changes in a new migration whose `down_revision` is the merge's `revision`. The merge itself becomes `pass`/`pass`.

### Core→{{PRIMARY_REPO_NAME}} ordering warning — Check 3g

1. Ensure the {{PRIMARY_REPO_NAME}} PR is merged to develop AND deployed to the target environment before merging {{PRIMARY_REPO_NAME}}.
2. Add a cross-reference in both PR descriptions naming the counterpart PR and the required merge order.
3. If {{PRIMARY_REPO_NAME}} is gated behind a feature flag, the order is advisory only (the flag prevents the missing-column path).

### Untrimmed autogen boilerplate — Check 3h

Open the migration. Keep only the `op.*` calls that match the PR's stated scope. Delete the rest from both `upgrade()` and `downgrade()`. Remove now-unused imports (`from sqlalchemy.dialects import postgresql`, `import sqlalchemy as sa`) when their symbols are no longer referenced. The `# ### commands auto generated ...` comment can stay or go — what matters is the content.

### Orphaned tenant stamps — Check 3i

For each `(tenant, schema)` where `alembic_version.version_num` can't be resolved on the current branch:

1. Identify the orphan revision's lineage. `git log --all --remotes -- alembic/versions/<schema>/*<orphan>*.py` finds the file in history (even if rebased/deleted from develop). Open it and read `down_revision`.
2. Classify the orphan:
   - **Empty merge** (upgrade/downgrade are `pass/pass`): schema-safe. Re-stamp to any ancestor on the current branch. Default choice: develop's head for that schema at the branch point.
   - **Feature-branch migration run against staging for testing, never merged**: if the DDL landed on develop under a different revision id, re-stamp to that. If not, the DB has drift — either land the migration properly (new PR) or create a downgrade to revert the partial state before re-stamping.
   - **Real DDL with no develop equivalent**: do not auto-fix; escalate.
3. Apply the stamp using the same helpers `run_all_migrations.py` uses to resolve the tenant connection (`AccountRegistry` + `DBProviderClient.build_connection_string(..., pooled=True)`), then call `command.stamp(cfg, target, purge=True)` scoped to `version_table='alembic_version'` + `version_table_schema='<schema>'` + `version_locations='alembic/versions/<schema>'`. `purge=True` wipes the orphan row first so alembic doesn't try to resolve it.
4. Verify: read `SELECT version_num FROM <schema>.alembic_version` — should equal the target. Then re-run `run_all_migrations.py` to apply forward migrations on top.

---

## Rules ({{COMPANY_SLUG}}-specific)

1. NEVER modify existing migrations that are already on `develop` or `main`.
2. Only modify migrations that exist ONLY on the current feature branch.
3. Merge migrations must be empty — `pass` in both `upgrade()` and `downgrade()`.
4. One linear chain — avoid branching by rebasing before merging PRs.
5. Run `alembic heads` to verify single head before pushing.
6. Autogenerate picks up unrelated drift — always trim to PR-scope changes only. **In {{PRIMARY_REPO_NAME}} this drift is always heavy** (20–40 unrelated ops); trim aggressively.
7. A depended-on repo's migrations must run before a dependent repo's (the dependent may reference the depended-on repo's tables). Run migrations in dependency order; a dependent repo's migrations must not depend on unreleased tables from another repo.
8. {{PRIMARY_REPO_NAME}} must NOT declare FKs into the `{{PRIMARY_REPO_NAME}}.*` schema.

---

## Best-Practice Prevention

Surface these at the end of every SAFE run to prevent future conflicts:

1. **Always `git fetch origin develop` before running `alembic revision --autogenerate`.** Running against a stale develop tip guarantees a stale `down_revision`.
2. **Never hand-write migrations.** Autogenerate first, then trim. ({{COMPANY_SLUG}} has a hook that blocks hand-written migrations.)
3. **One migration file per PR** unless there's a concrete reason. Multi-migration PRs make rebasing harder.
4. **Run `alembic heads` locally** before pushing. One head = safe. Two or more = fix before pushing.
5. **When in doubt, rebase over merge.** Linear history is easier to reason about and easier to revert.
6. **Never run an unmerged migration against staging** (or any shared tenant DB). The `alembic_version` row outlives your feature branch — if the migration is rebased away or never merged, the stamp becomes orphaned and the next scheduled `run_all_migrations` run fails for that tenant (Check 3i). If you need to validate a migration against realistic data, use a throwaway DB provider branch of the tenant DB, or use `ENFORCE_DEV_DATABASE_URL` against a local dev database.

---

## References

- [Alembic: Working with Branches](https://alembic.sqlalchemy.org/en/latest/branches.html) — official multi-head / merge guidance.
- [Resolving alembic merge branch conflicts — Michael Cho](https://michaelcho.me/article/resolving-alembic-merge-branch-conflicts/) — practical merge walkthrough.
- [Multiple heads in alembic migrations — Jerry Codes](https://blog.jerrycodes.com/multiple-heads-in-alembic-migrations/) — diagnosis patterns.
- [Fixing Alembic's Multiple Heads Problem with Git — jd](https://julien.danjou.info/blog/fixing-alembics-multiple-heads-problem-with-git/) — git-based automatic ordering.
- [Making Alembic migrations more team-friendly — Alan blog](https://medium.com/alan/making-alembic-migrations-more-team-friendly-e92997f60eb2) — team workflow strategies.
