#!/bin/bash
# qshipmaster-deliver.sh — final delivery for a fully-merged epic.
# Push <epic_branch> per repo, open ONE consolidated PR per repo, run
# code-review:code-review on each, post a per-wave summary comment.
#
# Usage: qshipmaster-deliver.sh <EPIC>
#
# Idempotent: detects existing PRs by branch and skips creation; re-running
# just refreshes the summary comment.

set -eo pipefail

EPIC="${1:-}"
if [ -z "$EPIC" ]; then echo "Usage: $0 <EPIC-ID>" >&2; exit 2; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qshipmaster-state.sh
source "$SCRIPT_DIR/qshipmaster-state.sh"

export GH_HOST="${GH_HOST:-{{GH_HOST}}}"
REPO_ROOT="${REPO_ROOT:-{{CODEBASE_ROOT}}}"

EPIC_DIR=$(state_dir "$EPIC")
LOG="$EPIC_DIR/logs/deliver.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

EPIC_BRANCH=$(state_get "$EPIC" '.epic_branch')
BASE_BRANCH=$(state_get "$EPIC" '.base_branch')
EPIC_TITLE=$(state_get "$EPIC" '.epic_summary')
REPOS=(); while IFS= read -r line; do REPOS+=("$line"); done < <(state_get "$EPIC" '.repos[]')

# Verify all waves are either shipped or explicitly deferred. Deferred waves
# (status == "deferred") are intentionally held back from this deploy — their
# ticket branches remain intact for a follow-up epic. The deliver phase
# proceeds with the shipped-wave subset.
unfinished=$(state_get "$EPIC" '[.waves[] | select(.status != "shipped" and .status != "deferred")] | length')
if [ "$unfinished" != "0" ]; then
    echo "[$(ts)] HALT: $unfinished wave(s) still not shipped or deferred — refusing to deliver" | tee -a "$LOG"
    state_status "$EPIC" | tee -a "$LOG"
    exit 6
fi
deferred_waves=$(state_get "$EPIC" '[.waves[] | select(.status == "deferred") | .n] | join(",")')
[ -n "$deferred_waves" ] && echo "[$(ts)] NOTE: wave(s) $deferred_waves DEFERRED from this deploy — their ticket branches remain available for a follow-up epic." | tee -a "$LOG"

# Build the Stories Included table from state.json + Jira children manifest.
JIRA="$EPIC_DIR/jira.json"
build_pr_body() {
    local repo="$1"
    local body_file="$EPIC_DIR/${repo}-pr-body.md"
    {
        echo "## Summary"
        echo ""
        echo "- Epic ${EPIC} (${EPIC_TITLE}) — consolidated delivery for repo \`${repo}\`."
        echo "- $(state_get "$EPIC" '.waves | length') wave(s) merged in dependency order."
        echo ""
        echo "## Stories Included"
        echo ""
        echo "| Story | Summary | Wave |"
        echo "|-------|---------|------|"
        local n
        n=$(state_get "$EPIC" '.waves | length')
        for i in $(seq 1 "$n"); do
            tickets=(); while IFS= read -r line; do tickets+=("$line"); done < <(state_get "$EPIC" ".waves[$((i - 1))].tickets[]")
            for t in "${tickets[@]}"; do
                local summary
                summary=$(jq -r --arg k "$t" '.children[] | select(.key == $k) | .summary // ""' < "$JIRA" 2>/dev/null || echo "")
                local trepo
                trepo=$(jq -r --arg k "$t" '.children[] | select(.key == $k) | .repo // ""' < "$JIRA" 2>/dev/null || echo "")
                # Only include rows for tickets actually touching this repo
                if [ "$trepo" = "$repo" ]; then
                    echo "| $t | $summary | $i |"
                fi
            done
        done
        echo ""
        echo "## Jira"
        echo ""
        echo "https://{{COMPANY_SLUG_LOWER}}.atlassian.net/browse/${EPIC}"
        echo ""
        echo "## Test plan"
        echo ""
        echo "- [x] Per-wave Phase 2 review (lint + pytest) recorded under \`{{STATE_ROOT}}/epic-${EPIC}/wave-N-phase3-evidence.md\`"
        echo "- [ ] CI green on this PR"
        echo "- [ ] Manual smoke check of changed surfaces"
    } > "$body_file"
    echo "$body_file"
}

deliver_one_repo() {
    local repo="$1"
    local repo_dir="$REPO_ROOT/$repo"

    if [ ! -d "$repo_dir/.git" ]; then
        echo "[$(ts)] [$repo] not a git repo — skipping" | tee -a "$LOG"
        return 0
    fi

    cd "$repo_dir"
    git checkout "$EPIC_BRANCH"

    # 1. Push branch.
    if ! git rev-parse --verify "origin/$EPIC_BRANCH" >/dev/null 2>&1; then
        echo "[$(ts)] [$repo] pushing $EPIC_BRANCH..." | tee -a "$LOG"
        git push -u origin "$EPIC_BRANCH" 2>&1 | tee -a "$LOG"
    else
        echo "[$(ts)] [$repo] $EPIC_BRANCH already on origin — pushing any local commits" | tee -a "$LOG"
        git push origin "$EPIC_BRANCH" 2>&1 | tee -a "$LOG" || true
    fi

    # 2. PR — detect existing first.
    local existing_pr
    existing_pr=$(gh pr list --head "$EPIC_BRANCH" --json url,number --jq '.[0].url' 2>/dev/null || echo "")
    local pr_url="$existing_pr"
    if [ -z "$pr_url" ]; then
        local body_file
        body_file=$(build_pr_body "$repo")
        echo "[$(ts)] [$repo] creating consolidated PR..." | tee -a "$LOG"
        pr_url=$(gh pr create \
            --title "${EPIC} ${EPIC_TITLE}" \
            --body-file "$body_file" \
            --base "$BASE_BRANCH" \
            --head "$EPIC_BRANCH" 2>&1 | tee -a "$LOG" | tail -1)
    else
        echo "[$(ts)] [$repo] PR already exists: $pr_url" | tee -a "$LOG"
    fi

    state_set "$EPIC" ".pr_url_per_repo[\"$repo\"]" "$pr_url"

    # 3. Final per-wave summary comment.
    local summary_file="$EPIC_DIR/${repo}-summary-comment.md"
    {
        echo "## qshipmaster summary — ${EPIC}"
        echo ""
        local n
        n=$(state_get "$EPIC" '.waves | length')
        for i in $(seq 1 "$n"); do
            local wave_evidence="$EPIC_DIR/wave-${i}-phase3-evidence.md"
            local tickets
            tickets=$(state_get "$EPIC" ".waves[$((i - 1))].tickets | join(\", \")")
            echo "### Wave $i"
            echo ""
            echo "Tickets: $tickets"
            if [ -f "$wave_evidence" ]; then
                echo ""
                echo "<details><summary>Phase 2 evidence</summary>"
                echo ""
                echo '```'
                tail -50 "$wave_evidence"
                echo '```'
                echo "</details>"
            fi
            echo ""
        done
    } > "$summary_file"
    gh pr comment "$pr_url" --body-file "$summary_file" 2>&1 | tee -a "$LOG" || true

    # 4. code-review skill via headless claude — Step 13 PRIMARY review.
    # Per the pipeline-wide effort pattern (review = high), this is the first
    # pass on the consolidated epic PR; the critic in step 5 provides a
    # second opinion AFTER this runs.  Spending high reasoning here catches
    # the biggest cross-wave issues before the critic does its pass.
    #
    # Override knobs:
    #   QSHIP_PR_REVIEW_MODEL    (default opus[1m])
    #   QSHIP_PR_REVIEW_EFFORT   (default high)
    echo "[$(ts)] [$repo] running code-review:code-review on $pr_url" | tee -a "$LOG"
    claude --print --dangerously-skip-permissions \
        --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,Task,TodoWrite,WebSearch,WebFetch' \
        --model "${QSHIP_PR_REVIEW_MODEL:-opus[1m]}" \
        --effort "${QSHIP_PR_REVIEW_EFFORT:-high}" \
        "Use the code-review:code-review skill on PR $pr_url. Post review comments directly to the PR." \
        > "$EPIC_DIR/logs/${repo}-code-review.log" 2>&1 || true

    # 5. External-model critic — mirrors ralphex Phase 3 (different model family
    # catching blind spots from the primary reviewer). Different family from
    # the primary (opus[1m]); cheap, fast, sees the same diff with different
    # priors. Critic posts ONE consolidated comment, not per-line nits.
    #
    # Engine selection (2026-05 migration + 2026-05 follow-up).
    #   The critic mirrors whatever Phase 2 review engine the user opted into
    #   when invoking /qship or /qshipmaster.  If the user passed reviewer=codex
    #   (which exports QSHIP_REVIEW_ENGINE=codex), the Step 13 critic also uses
    #   codex — that's the diversified opus-implements + codex-reviews stance
    #   end-to-end.  If the user did NOT opt into reviewer=codex, Step 13 stays
    #   on the original sonnet critic — we don't sneak codex into a pipeline
    #   the user didn't ask for.
    #
    #   Resolution order:
    #     1. QSHIP_CRITIC_ENGINE — explicit override (codex|sonnet)
    #     2. QSHIP_REVIEW_ENGINE=codex + codex CLI available → codex
    #     3. otherwise → sonnet (original behaviour)
    #
    # Override via QSHIP_CRITIC_ENGINE={codex|sonnet}, QSHIP_CODEX_CRITIC_MODEL,
    # QSHIP_CODEX_CRITIC_EFFORT.
    critic_engine="${QSHIP_CRITIC_ENGINE:-}"
    if [ -z "$critic_engine" ]; then
        if [ "${QSHIP_REVIEW_ENGINE:-}" = "codex" ] && command -v codex >/dev/null 2>&1; then
            critic_engine="codex"
        else
            critic_engine="sonnet"
        fi
    fi

    if [ "$critic_engine" = "codex" ]; then
        echo "[$(ts)] [$repo] running codex critic (gpt-5.5 high) on $pr_url" | tee -a "$LOG"
        critic_body_file="$EPIC_DIR/logs/${repo}-codex-critic.body"
        critic_err_file="$EPIC_DIR/logs/${repo}-codex-critic.err"
        critic_prompt_file="$EPIC_DIR/logs/${repo}-codex-critic.prompt"

        # Gather inputs once on the orchestrator side — codex needs neither
        # a sandbox for gh nor any tool permissions beyond stdin.
        gh pr diff "$pr_url" > "$critic_prompt_file.diff" 2>/dev/null || echo "<diff unavailable>" > "$critic_prompt_file.diff"
        pr_path="$(printf '%s' "$pr_url" | sed -E 's|.*github\.com/([^/]+/[^/]+)/pull/.*|\1|')"
        pr_num="$(basename "$pr_url")"
        gh api "repos/${pr_path}/pulls/${pr_num}/comments" > "$critic_prompt_file.comments" 2>/dev/null || echo '[]' > "$critic_prompt_file.comments"

        # Build the prompt file via heredoc with QUOTED delimiter (no expansion),
        # then envsubst-style sed for the two variables we need.
        cat > "$critic_prompt_file" <<'CRITIC_PROMPT'
You are a SECOND-OPINION critic on a pull request. A primary reviewer (opus[1m] + code-review:code-review skill) has already posted comments.

PR URL: __PR_URL__

PR DIFF (full):
```
__PR_DIFF_PLACEHOLDER__
```

EXISTING REVIEW COMMENTS (JSON):
```
__PR_COMMENTS_PLACEHOLDER__
```

Look for issues the primary review MISSED — specifically:
(a) cross-file invariants the diff breaks
(b) silent failures / swallowed exceptions
(c) test coverage gaps for the new behaviour
(d) security implications (input trust boundaries, secrets, auth bypasses)
(e) data-shape changes that break API/DB contracts

Output ONE consolidated section, formatted as a GitHub markdown comment, with the heading:
    ## Codex critic (gpt-5.5 high) — second opinion

followed by a short bullet list of findings (file:line where applicable).

If you find no additional issues NOT already covered by the primary reviewer, output exactly:
    ## Codex critic (gpt-5.5 high) — no additional findings

and nothing else.

Do not duplicate the primary reviewer's points. Do not include any preamble, meta-commentary, or trailing text outside the section heading + bullets — the entire output will be posted verbatim as a PR comment.
CRITIC_PROMPT

        # Substitute PR_URL inline.
        sed -i.bak "s|__PR_URL__|$pr_url|" "$critic_prompt_file" && rm -f "${critic_prompt_file}.bak"
        # Insert diff + comments via awk (avoids sed escaping nightmare for arbitrary content).
        awk -v diff_file="$critic_prompt_file.diff" -v comments_file="$critic_prompt_file.comments" '
            /__PR_DIFF_PLACEHOLDER__/   { while ((getline line < diff_file)     > 0) print line; close(diff_file);     next }
            /__PR_COMMENTS_PLACEHOLDER__/ { while ((getline line < comments_file) > 0) print line; close(comments_file); next }
            { print }
        ' "$critic_prompt_file" > "${critic_prompt_file}.expanded" && mv "${critic_prompt_file}.expanded" "$critic_prompt_file"

        # codex exec invocation — verified against codex-cli 0.130.0 (2026-05).
        # Flags chosen so the critic is:
        #   -o <file>                   → writes ONLY the assistant's final message
        #                                 to that file (no preamble parsing needed).
        #   -s read-only                → critic does no writes; sandbox accordingly.
        #   --skip-git-repo-check       → the orchestrator runs from /tmp where there
        #                                 is no .git; codex would otherwise refuse.
        #   --ephemeral                 → don't persist session files for a one-shot
        #                                 review run.
        # stderr captures session metadata + token usage (informational).
        if codex exec \
            --model "${QSHIP_CODEX_CRITIC_MODEL:-gpt-5.5}" \
            -c "model_reasoning_effort=${QSHIP_CODEX_CRITIC_EFFORT:-high}" \
            -s read-only \
            --skip-git-repo-check \
            --ephemeral \
            -o "$critic_body_file" \
            - < "$critic_prompt_file" > /dev/null 2> "$critic_err_file"; then
            if [ -s "$critic_body_file" ]; then
                gh pr comment "$pr_url" --body-file "$critic_body_file" 2>&1 | tee -a "$LOG" || true
            else
                echo "[$(ts)] [$repo] codex critic produced empty body — see $critic_err_file" | tee -a "$LOG"
            fi
        else
            echo "[$(ts)] [$repo] codex critic failed (see $critic_err_file) — falling back to sonnet" | tee -a "$LOG"
            critic_engine="sonnet"
        fi
    fi

    if [ "$critic_engine" = "sonnet" ]; then
        echo "[$(ts)] [$repo] running sonnet critic on $pr_url" | tee -a "$LOG"
        claude --print --dangerously-skip-permissions \
            --allowedTools 'Bash,Read,Grep,Glob' \
            --model 'sonnet' \
            "You are a SECOND-OPINION critic on PR $pr_url (an opus reviewer already posted comments). Fetch the diff with 'gh pr diff $pr_url' and the existing review comments with 'gh api repos/{owner}/{repo}/pulls/{number}/comments'. Look for issues the primary review MISSED — specifically: (a) cross-file invariants the diff breaks, (b) silent failures / swallowed exceptions, (c) test coverage gaps for the new behaviour, (d) security implications (input trust boundaries, secrets, auth bypasses), (e) data-shape changes that break API/DB contracts. Post ONE consolidated comment via 'gh pr comment $pr_url --body <findings>' with the heading '## Sonnet critic — second opinion' followed by a short bullet list. If you find no additional issues, post '## Sonnet critic — no additional findings' and stop. Do not duplicate the primary reviewer's points." \
            > "$EPIC_DIR/logs/${repo}-sonnet-critic.log" 2>&1 || true
    fi
}

# Epic-end Phase 3 — runs ONCE on the cumulative merged diff across all waves
# BEFORE the deliver-per-repo loop. Wave-level Phase 3 only covers per-wave
# scenarios; this step catches CROSS-WAVE interactions (e.g. wave-1's helper ×
# wave-6's column-drop together) that per-wave evidence cannot prove.
#
# Two-stage flow per the user's request (added after {{JIRA_PROJECT_KEY}}-EX07):
#   1. superpowers:brainstorming designs a comprehensive scenario matrix that
#      explicitly covers cross-wave interactions, edge cases, and any UI/API
#      surface added across the epic. Output: epic-scenario-matrix.md.
#   2. /qe2etest exercises every scenario in the matrix against the consolidated
#      merged epic branch, capturing per-scenario artifacts (curl/SQL/Playwright)
#      under $EPIC_DIR/epic-test-results/. Output: epic-phase3-evidence.md.
#
# Hard gate: epic-end Phase 3 must produce epic-phase3-evidence.md with all
# scenarios PASS before deliver-per-repo runs. If any scenario fails or the
# matrix step times out, HALT — do NOT create PRs against unverified diffs.
EPIC_PHASE3_TIMEOUT_SEC="${QSHIP_EPIC_PHASE3_TIMEOUT_SEC:-14400}"
EPIC_PHASE3_LOG="$EPIC_DIR/logs/epic-phase3.log"
EPIC_PHASE3_EVIDENCE="$EPIC_DIR/epic-phase3-evidence.md"
EPIC_SCENARIO_MATRIX="$EPIC_DIR/epic-scenario-matrix.md"
mkdir -p "$EPIC_DIR/epic-test-results"

# Aggregate every wave's required-scenarios.json under each ticket so the
# brainstorm has full coverage context.
SCENARIO_INPUTS=""
for ticket in $(state_get "$EPIC" '[.waves[].tickets[]] | .[]'); do
    f="{{STATE_ROOT}}/worktrees/$ticket/required-scenarios.json"
    [ -f "$f" ] && SCENARIO_INPUTS="$SCENARIO_INPUTS $f"
done

echo "[$(ts)] EPIC PHASE 3 — designing scenario matrix via brainstorming" | tee -a "$LOG"
_timeout_bin="$(command -v timeout || command -v gtimeout || true)"
[ -z "$_timeout_bin" ] && _timeout_bin=":"

# Stage 1: brainstorm the matrix.
"$_timeout_bin" --kill-after=30s "$EPIC_PHASE3_TIMEOUT_SEC" \
claude --print --dangerously-skip-permissions \
    --allowedTools 'Bash,Read,Grep,Glob,Write,Edit,Task,TodoWrite,WebSearch,mcp__*' \
    --model "${QSHIP_EPIC_PHASE3_DESIGN_MODEL:-opus[1m]}" \
    --effort "${QSHIP_EPIC_PHASE3_DESIGN_EFFORT:-xhigh}" \
    --append-system-prompt 'EPIC-END PHASE 3 SCENARIO DESIGN. The epic is fully merged across all waves. Your job is to design a COMPREHENSIVE, ROBUST scenario matrix that proves the cumulative merged diff is shippable.

EXHAUSTIVENESS MANDATE — non-negotiable.

The downstream /qe2etest stage must cover ALL possible scenarios. For each changed code path in the cumulative diff, decide which trigger surfaces it touches — DB, API, UI, worker, cron, or any combination — and design scenarios for EVERY one of them. Do not stop at the happy path. Cover the full scenario taxonomy: happy paths, edge cases, boundary conditions, error paths, adversarial inputs, authz boundaries, regression on adjacent flows, state transitions, persistence / round-trip, idempotency, and especially CROSS-WAVE interactions that per-wave Phase 3 evidence cannot prove. If a scenario will need test data that does not exist locally, design the seed script alongside the scenario row so the executor seeds-before-running. Per-wave evidence files exist; read them, then go beyond them.' \
    "Use the superpowers:brainstorming skill to design an epic-end Phase 3 scenario matrix for epic ${EPIC} (${EPIC_TITLE}) on branch ${EPIC_BRANCH:-${EPIC}-${EPIC_TITLE}}.

Per-wave inputs (read each):
- Per-wave evidence: $EPIC_DIR/wave-1-phase23-evidence.md through wave-6-phase23-evidence.md (whichever exist)
- Per-ticket required-scenarios.json:${SCENARIO_INPUTS}
- Cumulative diff: \`git diff ${BASE_BRANCH}..HEAD\` in each repo under $REPO_ROOT
- Jira epic JSON: $EPIC_DIR/jira.json

REQUIREMENTS for the matrix:
1. **Surface classification per scenario (mandatory)** — for every changed code path, decide which trigger surfaces it touches: DB / API / UI / worker / cron / or any combination. Design one or more scenarios per surface. A change that touches three surfaces (e.g., new endpoint that writes to DB AND fires a worker job AND surfaces a notification in the UI) gets at LEAST one scenario per surface, plus one cross-surface scenario that exercises them together.
2. **Comprehensive AC coverage** — every acceptance criterion from every child ticket gets at least 5 scenarios (happy_path, negative, boundary, edge, auth) — same matrix shape /qship uses per-ticket.
3. **Cross-wave interactions** — explicitly enumerate scenarios that exercise functionality from two-or-more waves together. Examples for the multi-wave shape: (a) a wave-1 helper invoked against wave-6 post-cleanup schema, (b) a wave-3 feature flag toggled while a wave-4 reader is in-flight, (c) wave-5 deprecation logging exercised by a wave-2 caller that has not yet migrated. Find the analogous cross-wave seams for THIS epic.
4. **Adversarial scenarios** — for every behavioral guarantee the epic claims, design at least one scenario that would expose violation (idempotency violations, concurrent-writer races, partial-rollback states, migration rollback path, etc.).
5. **Seed-data scripts inline** — for any scenario whose test data is not present in the default \`local_demo_db\`, design a \`seed-S<id>.sh\` script (idempotent INSERT … ON CONFLICT DO NOTHING) alongside the matrix row. The executor will run the seed script before the scenario.

OUTPUT: write the matrix to $EPIC_SCENARIO_MATRIX as a Markdown file with columns: ID | Type (single-wave|cross-wave|adversarial) | Surface (db|api|ui|worker|cron|cross) | AC | Scenario | Method (pytest|curl|psql|playwright) | Concrete invocation | Seed script path (or 'none'). Minimum 30 scenarios, target 50+. End with a one-line invariants block:
\`\`\`
INVARIANTS: every row in the matrix must be exercisable via the listed Method without manual setup beyond DEV_MODE=true python serve.py (background per Bash-tool safe-detach rules), the default local_demo_db (or the DB cited in the row), and the seed script (if any).
\`\`\`

After writing the matrix, exit cleanly. Do NOT run /qe2etest in this step — that is a separate stage." \
    > "$EPIC_PHASE3_LOG" 2>&1 || true

if [ ! -s "$EPIC_SCENARIO_MATRIX" ]; then
    echo "[$(ts)] HALT: epic Phase 3 matrix design failed — $EPIC_SCENARIO_MATRIX missing or empty. Inspect $EPIC_PHASE3_LOG." | tee -a "$LOG"
    state_set "$EPIC" '.status' 'blocked'
    state_set "$EPIC" '.error' "epic-end Phase 3: scenario matrix design failed"
    exit 8
fi

echo "[$(ts)] EPIC PHASE 3 — executing scenarios via /qe2etest" | tee -a "$LOG"

# Stage 2: run /qe2etest against the matrix on the consolidated branch.
"$_timeout_bin" --kill-after=30s "$EPIC_PHASE3_TIMEOUT_SEC" \
claude --print --dangerously-skip-permissions \
    --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,Task,TodoWrite,WebSearch,WebFetch' \
    --model "${QSHIP_EPIC_PHASE3_EXEC_MODEL:-opus[1m]}" \
    --effort "${QSHIP_EPIC_PHASE3_EXEC_EFFORT:-high}" \
    --append-system-prompt 'EPIC-END PHASE 3 EXECUTION (I8 invariant, hook-enforced).

** /qe2etest IS THE ONLY ACCEPTABLE SOURCE OF EPIC-END PHASE 3 EVIDENCE **
** pytest, TestClient, raw curl, psql output — ALL FORBIDDEN as the PRIMARY method column. **
** Citing them in a row''s Method column without a qe2etest: prefix WILL be rejected by the validator hook. **

The evidence file path is EXACTLY (do not abbreviate, do not shorten any character):

  $EPIC_DIR/epic-phase3-evidence.md

Where $EPIC_DIR resolves to {{STATE_ROOT}}/epic-<EPIC_ID>/. The validator hook also checks for {{STATE_ROOT}}/epic-<EPIC_ID>/epic-qe2etest.log; deliver.sh symlinks one to the other automatically — you only need to write epic-phase3-evidence.md.

REQUIRED EVIDENCE FORMAT (the validator parses this exactly):

The file MUST contain a section with this EXACT LITERAL heading (em-dash, lowercase, no extra words):

  ## Phase 3 — /qe2etest evidence

Inside that section, provide a markdown table with rows formatted as:

  | ID | Method | DB used | Artifact path | Verdict | Fix-attempt |
  |---|---|---|---|---|---|
  | S1 | qe2etest:GET /api/v1/policies/peers/?org_id=... | local_demo_db | {{STATE_ROOT}}/epic-<EPIC>/epic-test-results/s1-curl.txt | PASS | none |
  | S2 | qe2etest:Playwright RecordList badges | local_demo_db | {{STATE_ROOT}}/epic-<EPIC>/epic-test-results/s2-screenshot.png | PASS | none |
  | S3 | qe2etest:pytest tests/integration/test_rules_engine.py::test_skipped_reason_persisted | local_alt_db | {{STATE_ROOT}}/epic-<EPIC>/epic-test-results/s3-pytest.log | PASS | none |

Critical formatting rules (enforced by validator):

(1) The Method column of EVERY row MUST start with literal "qe2etest:" (note the colon). The /qe2etest skill drives the underlying tool — pytest, curl, psql, Playwright — but the row marks the verification as qe2etest-driven via the prefix. Rows whose Method column starts with "pytest:" or "curl:" or "psql:" WITHOUT the qe2etest: prefix WILL be rejected as Phase 2 evidence (banlist).

(2) The section MUST end with an explicit positive verdict line. Either:

  Verdict: SHIPPABLE

(if all rows PASS or have justified SKIPs) OR:

  Verdict: NOT_SHIPPABLE

(if any row FAILs after MAX_FIX_ITERS). The validator BLOCKS PR creation unless "Verdict: SHIPPABLE" appears.

(3) Empty scenario tables (header only, zero data rows) WILL be rejected — the validator counts rows below the `| --- |` separator. The orchestrator''s gate (deliver.sh post-execution) ALSO counts rows.

(4) The "no qe2etest surface" escape hatch is NOT available for the epic-end pass — the cumulative diff almost always touches FastAPI/React/alembic surfaces. Run the scenarios.

SERVER SPIN-UP: Use safe-detach: `nohup env DEV_MODE=true python serve.py > /tmp/server-epic.log 2>&1 < /dev/null & disown`, then poll readiness with a 60s wall-clock cap before any scenario runs. Playwright invocations MUST wrap browser_wait_for in a 30s timeout.

HEARTBEAT: every 5 minutes during execution, touch $EPIC_DIR/epic-phase3-heartbeat.txt with the current scenario ID. Supervisor uses this file''s mtime — if claude is mid-pytest or mid-Playwright for a long-running scenario, the heartbeat keeps the supervisor from SIGTERM-ing prematurely. NEVER let the heartbeat go stale for >12 min unless you are genuinely done.



PER-SCENARIO DATABASE SELECTION (non-negotiable): different local Postgres DBs carry different test-data shapes. Pick the most data-rich DB for each scenario rather than running everything against `local_demo_db`. The mapping below is the canonical default — overrideable per scenario if its matrix row cites a specific DB. Use the `DATABASE_URL=postgresql://{{LOCAL_DB_USER}}@localhost:5432/<db>` form when spawning the server, AND restart the server between DB switches (the same uvicorn process holds a connection pool to one DB; you cannot hot-swap).

| Scenario category | Default DB | Why |
|---|---|---|
| Reference-document matching, record-to-reference reconciliation, reconciliation match, classification policies that touch reference documents | `local_alt_db` | densest matching corpus locally — best for matching algorithms, edge cases on quantity/price drift, multi-line record scenarios |
| Validation policy templates / instances exercising real record data, catalogs, taxonomies — the default for most scenarios | `local_demo_db` | Demo Tenant has the densest item/policy/tag data locally — canonical default for validation-policy scenarios |
| (your-domain) entities, Sample Category catalogs, sample taxonomies specifically | `local_acme_corp_db` | Acme Corp has (your domain)-tuned catalog/policy data; use only when a scenario explicitly needs (your-domain) shapes |
| Multi-tenant org-scoping / RLS / membership table behaviour where you need 3+ orgs across tenants | `{{LOCAL_DEV_DB_NAME}}` | Has multiple tenant orgs (3) and is the canonical multi-tenant smoke-test DB |
| Schema-only / Pydantic-validator / OpenAPI / pure-unit tests with no DB dependency | any (prefer `local_demo_db` for parity with wave-level evidence) | Schema validation does not query the DB |
| Migration alembic up/down / schema introspection / RLS policy SQL | `local_demo_db` (or whichever holds the most recent migrated state) | Migrations operate on schema not data |
| Connector ingestion (external CRM/accounting connector, ERP, webhooks) — cross-tenant routing, deprecation logging | `{{LOCAL_DEV_DB_NAME}}` | Multi-tenant routing requires multiple orgs |

Procedure per scenario:
(a) Determine the scenario''s data needs from the matrix row (which entities does it query/mutate?).
(b) Pick the DB from the table above; if the matrix row explicitly cites a DB, use that instead.
(c) If the running server is on a different DB, kill it cleanly (`pkill -f "serve.py"`), wait 2s, then respawn with `nohup env DATABASE_URL=postgresql://{{LOCAL_DB_USER}}@localhost:5432/<chosen_db> DEV_MODE=true python serve.py > /tmp/server-epic-<db>.log 2>&1 < /dev/null & disown` and poll readiness.
(d) Capture the chosen DB name in the scenario''s evidence row (column "DB used") so reviewers can reproduce.
(e) Group scenarios by DB to amortize the server-restart cost — run all `local_demo_db` scenarios in one batch (this is the default and will usually be the largest group), then all `local_alt_db`, then any `local_acme_corp_db` or `{{LOCAL_DEV_DB_NAME}}` scenarios. Aim for <=3 server restarts across the entire matrix.

If a scenario requires a fixture that does not exist in ANY local DB, write the SKIP rationale citing the missing data, AND open a one-line note to {{STATE_ROOT}}/epic-<EPIC>/inbox/db-fixture-gap-<ts>.md so a follow-up can seed the data. Do NOT spin up an empty fresh DB for one scenario — local seed data is the point of these DBs.' \
    "Execute /qe2etest against the epic-${EPIC} scenario matrix at $EPIC_SCENARIO_MATRIX on branch ${EPIC_BRANCH:-${EPIC}-${EPIC_TITLE}} (repos under $REPO_ROOT).

EXHAUSTIVENESS MANDATE — non-negotiable.
You need to /qe2etest ALL possible scenarios in the matrix — DB, API, UI, worker, cron, or any combination. Do not skip surfaces. Fix any bugs you find along the way (fix-in-line loop below), and seed any data needed to fully complete each scenario (run seed-S<id>.sh scripts when present, or write your own seed scripts under $EPIC_DIR/seed-S<id>.sh when the matrix flagged a data gap). The matrix is complete only when every changed surface has been exercised AND every bug found has been fixed AND every scenario re-verifies green.

Procedure:
1. Read $EPIC_SCENARIO_MATRIX in full.
2. Group scenarios by Method: pytest, curl, psql, playwright.
3. For pytest scenarios: collect the named functions, run them in one batch per repo.
4. For curl/psql scenarios: spin up the local server (safe-detach per system prompt), then execute each invocation, capturing status+response.
5. For playwright scenarios: drive the running UI via the Playwright MCP (--headless --isolated --browser chromium per ~/.claude/plugins/.../playwright/.mcp.json), capture screenshots + DOM snapshots to $EPIC_DIR/epic-test-results/.
6. Append per-scenario rows to $EPIC_DIR/epic-phase3-evidence.md with columns: ID | Method | Artifact path | Verdict (PASS|FAIL|SKIP-with-rationale) | Fix-attempt (none|fixed-in-S<id>|escalated). At least one concrete artifact per scenario.

7. **FIX-IN-LINE LOOP (this is the key change — DO NOT just report-and-exit on failures).** When ANY scenario FAILs:
   (a) **Diagnose** — read the artifact (curl response, pytest traceback, psql error, playwright trace). Identify root cause: which file, which function, which line, which class of bug (regression, missing branch, schema drift, race condition, security gap, etc.).
   (b) **Decide fixability** by category:
       - REGRESSION introduced by waves 1-N of THIS epic on the merged epic branch → FIX IN-LINE. This is your job.
       - PRE-EXISTING bug on develop that the new code surfaced → FIX IN-LINE (commit cited as drive-by; mention in evidence as DRIVE-BY-FIX-FOR-PRE-EXISTING).
       - Genuine product spec ambiguity / unclear requirement → ESCALATE (write to epic-blocked.md, do NOT guess; this is a human-judgment call).
       - Test-fixture / test-data gap (the bug is in the test setup, not the system under test) → FIX the fixture in-line and re-run.
       - Environment problem (server didn'\''t start, DB connection refused, MCP timeout) → restart/retry up to 3× before escalating.
   (c) **Apply the fix** with EDIT/WRITE tools against the actual product code on the epic branch (\`$REPO_ROOT/<repo>\`). Commit each fix as its own commit with message: \`fix(phase3-${EPIC}): <one-line cause> (closes S<scenario-id>)\`. Use \`git add <specific-files>\` not \`git add -A\`.
   (d) **Re-run the failed scenario** end-to-end using the exact same Method as the original run. Capture a NEW artifact (don'\''t overwrite the original — name it \`S<id>-after-fix.txt\`). If it now PASSes, update the evidence row: \`Verdict: PASS | Fix-attempt: fixed-in-S<id>\`.
   (e) **Run regression set** — after each fix, also re-run the 5 scenarios IMMEDIATELY ADJACENT in the matrix (S<id-2> through S<id+2>) AND any scenario the matrix flagged as touching the same code path. If any of THOSE now fail (the fix broke them), revert the fix commit and ESCALATE — your fix had unintended consequences.
   (f) **Continue the matrix** — don'\''t stop at the first fix. Move on to the next FAILing scenario. Stop fix-iterations only when (i) all scenarios pass, OR (ii) you'\''ve made 10 fix-commits in this run (MAX_FIX_COMMITS cap) — at that point write all remaining failures to epic-blocked.md and escalate.

   Fix-loop guard rails (NON-NEGOTIABLE, will be hook-enforced):
   - NEVER apply a fix by weakening the test (pytest.skip, xfail, assert True, deleting test, try/except: pass, # noqa). The test is the spec; if the test is wrong, write a one-line rationale in the evidence row and ESCALATE — do not silently mute.
   - NEVER apply a fix that touches > 3 files in one commit. Larger blast radius = needs human review.
   - NEVER apply a fix to: alembic migrations on already-merged waves (would corrupt the chain), security/auth files (jwt, role checks, oauth_provider), or any file matching \`*secret*\`, \`*credential*\`, \`*.env*\`.
   - NEVER apply a fix that doesn'\''t have a focused commit message naming the scenario (\`closes S<id>\`).
   - If you find yourself debating whether a fix is safe, ESCALATE — that hesitation is the signal that a human should decide.

8. End the evidence file with a summary block:
\`\`\`
## Epic Phase 3 summary
- Total scenarios: <N>
- PASS (no fix needed): <P>
- PASS (after in-line fix): <PF>  (list of fix commits with shas)
- FAIL (could not fix, escalated): <F>
- SKIPPED: <S> (with rationale per skip)
- Cross-wave scenarios verified: <C>
- Fix commits made: <K>  (list shas + scenario IDs they closed)
- Verdict: SHIPPABLE | NOT_SHIPPABLE
\`\`\`

9. If ANY scenario remains FAILed after the fix-loop cap (or was un-fixable per category in 7b), write a paragraph diagnosis to $EPIC_DIR/epic-blocked.md citing exact file:line + recommended fix that a human should review. Exit non-zero — orchestrator HALTs PR creation. If all scenarios now pass (with or without in-line fixes), write \`Verdict: SHIPPABLE\` and exit 0.

NON-NEGOTIABLE (additive to fix-loop guard rails above): do NOT skip a scenario as 'no UI surface' or 'covered by unit tests' generically. If a scenario truly has no UI surface, the row in the matrix already marked it pytest/curl/psql. Skipping a row requires writing the rationale in the SKIP cell with file citation.

Bash-tool safe-detach rules apply (see system prompt). Heartbeat: every 5 min, touch $EPIC_DIR/epic-phase3-heartbeat.txt — the supervisor uses this to detect Phase-3 stalls." \
    >> "$EPIC_PHASE3_LOG" 2>&1 || true

# Hard gate (I8 invariant): epic Phase 3 evidence MUST exist AND contain a
# positive SHIPPABLE verdict AND pass the /qe2etest validator (banlist +
# heading + invocation/PASS or no-surface rationale).
#
# The OLD gate only blocked on negative signals (NOT_SHIPPABLE / FAIL:N), which
# meant a 300-byte file with an empty scenario table passed silently — that's
# the {{JIRA_PROJECT_KEY}}-EX06 epic-end gap. Tightened to require POSITIVE evidence.
if [ ! -s "$EPIC_PHASE3_EVIDENCE" ]; then
    echo "[$(ts)] HALT: epic Phase 3 execution failed — $EPIC_PHASE3_EVIDENCE missing or empty. Inspect $EPIC_PHASE3_LOG." | tee -a "$LOG"
    state_set "$EPIC" '.status' 'blocked'
    state_set "$EPIC" '.error' "epic-end Phase 3: execution failed"
    exit 9
fi

# Block on explicit failure signals (preserved from old gate).
if grep -qiE '^- (Verdict:[[:space:]]*NOT_SHIPPABLE|FAIL:[[:space:]]*[1-9])' "$EPIC_PHASE3_EVIDENCE"; then
    echo "[$(ts)] HALT: epic Phase 3 reports failures — refusing to create PRs. See $EPIC_PHASE3_EVIDENCE and $EPIC_DIR/epic-blocked.md." | tee -a "$LOG"
    state_set "$EPIC" '.status' 'blocked'
    state_set "$EPIC" '.error' "epic-end Phase 3: one or more scenarios FAILED"
    exit 10
fi

# NEW: require positive verdict line — "Verdict: SHIPPABLE" or equivalent.
# An empty file lacking BOTH NOT_SHIPPABLE and SHIPPABLE will be caught here.
if ! grep -qE '^-?[[:space:]]*Verdict:[[:space:]]*SHIPPABLE\b' "$EPIC_PHASE3_EVIDENCE"; then
    echo "[$(ts)] HALT: epic Phase 3 evidence has no explicit \"Verdict: SHIPPABLE\" line — refusing to create PRs. This blocks the {{JIRA_PROJECT_KEY}}-EX06-class regression where claude returned mid-execution and left an empty table. Re-run Phase 3 (matrix exec) until evidence carries a positive verdict, OR ESCALATE to user." | tee -a "$LOG"
    state_set "$EPIC" '.status' 'blocked'
    state_set "$EPIC" '.error' "epic-end Phase 3: missing 'Verdict: SHIPPABLE' line (likely empty scenario table)"
    exit 10
fi

# NEW: require at least one actual scenario row (not just table header).
# Header rows contain `| --- |` (markdown table separator); scenario rows have
# actual content. A file with only `| ID | Method | ... |` header + `| --- |`
# separator MUST be rejected.
scenario_rows=$(awk '
    /^\| --- / {sep_seen=1; next}
    sep_seen && /^\|/ && !/^\| ---/ {count++}
    END {print count+0}
' "$EPIC_PHASE3_EVIDENCE")
if [ "$scenario_rows" -lt 1 ]; then
    echo "[$(ts)] HALT: epic Phase 3 evidence has zero scenario rows (only table header). The Phase-3 execution claude likely returned before writing rows. Re-run, or ESCALATE." | tee -a "$LOG"
    state_set "$EPIC" '.status' 'blocked'
    state_set "$EPIC" '.error' "epic-end Phase 3: zero scenario rows in evidence table"
    exit 10
fi

# NEW: I8 banlist + /qe2etest section check via shared validator.
# Source the lib once (idempotent across deliver.sh invocations).
QSHIP_HOOKS_DIR="${HOME}/.claude/skills/qship/hooks"
if [ -f "$QSHIP_HOOKS_DIR/qship-evidence-lib.sh" ]; then
    # shellcheck source={{USER_HOME}}/.claude/skills/qship/hooks/qship-evidence-lib.sh
    source "$QSHIP_HOOKS_DIR/qship-evidence-lib.sh"
    epic_diff_ref="${BASE_BRANCH:-develop}..HEAD"
    epic_repo_dir="$REPO_ROOT/${REPOS[0]}"
    # Canonicalise a near-miss Phase 3 heading before validating (see lib) so a
    # cosmetic wording slip can't HALT epic delivery when the /qe2etest
    # substance is real — the validator's substance gates still decide.
    normalize_phase3_heading "$EPIC_PHASE3_EVIDENCE"
    if ! validate_qe2etest_evidence \
            "$EPIC_PHASE3_EVIDENCE" \
            "epic" \
            "$epic_diff_ref" \
            "$epic_repo_dir" \
            2>"$EPIC_DIR/epic-qe2etest-validator.err"; then
        err=$(cat "$EPIC_DIR/epic-qe2etest-validator.err" 2>/dev/null || echo "validation failed")
        echo "[$(ts)] HALT: epic Phase 3 evidence fails I8 (/qe2etest enforcement): $err" | tee -a "$LOG"
        state_set "$EPIC" '.status' 'blocked'
        state_set "$EPIC" '.error' "epic-end Phase 3: I8 violation — $err"
        exit 10
    fi

    # ALSO ensure the canonical epic-qe2etest.log exists per I8 spec.
    # deliver.sh historically writes to epic-phase3-evidence.md; create a
    # symlink/alias so both paths resolve to the same content for downstream
    # tooling (the require-phase3-evidence hook etc.).
    EPIC_QE2ETEST_LOG="$EPIC_DIR/epic-qe2etest.log"
    if [ ! -e "$EPIC_QE2ETEST_LOG" ]; then
        ln -s "$(basename "$EPIC_PHASE3_EVIDENCE")" "$EPIC_QE2ETEST_LOG" 2>/dev/null || \
          cp "$EPIC_PHASE3_EVIDENCE" "$EPIC_QE2ETEST_LOG"
    fi
else
    echo "[$(ts)] WARN: $QSHIP_HOOKS_DIR/qship-evidence-lib.sh missing — skipping I8 /qe2etest validation (legacy fallback)" | tee -a "$LOG"
fi

echo "[$(ts)] EPIC PHASE 3 PASSED — proceeding to per-repo deliver" | tee -a "$LOG"

for repo in "${REPOS[@]}"; do
    deliver_one_repo "$repo"
done

state_set "$EPIC" '.status' 'shipped'
state_set "$EPIC" '.shipped_at' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[$(ts)] DELIVERY COMPLETE for $EPIC" | tee -a "$LOG"
echo "PRs:" | tee -a "$LOG"
state_get "$EPIC" '.pr_url_per_repo | to_entries[] | "  \(.key): \(.value)"' | tee -a "$LOG"
