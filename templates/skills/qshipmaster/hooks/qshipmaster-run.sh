#!/bin/bash
# qshipmaster-run.sh — outer entry point. Orchestrates the full epic
# pipeline by composing qshipmaster-plan.sh, qship-persist.sh (per ticket per
# wave, in parallel), qshipmaster-merge-wave.sh, wave-level Phase 2 review,
# and qshipmaster-deliver.sh.
#
# Idempotent: re-running picks up exactly where the last run stopped, using
# {{STATE_ROOT}}/epic-<EPIC>/state.json as the truth.
#
# Usage:
#   qshipmaster-run.sh {{JIRA_PROJECT_KEY}}-EX01
#
# Env:
#   MAX_WAVE_ITERS       max polling intervals to wait for a wave (default 240 = 4h at 60s)
#   POLL_INTERVAL        seconds between barrier polls (default 60)
#   MAX_FIX_ITERS        max Phase 2 fix loops per wave (default 3)
#   QSHIP_PERSIST_PATH   path to qship-persist.sh (default ~/.claude/skills/qship/hooks/qship-persist.sh)

set -eo pipefail

# ---- OpenTelemetry: Claude Code → Phoenix (Arize) ----
# Export OTEL env vars at top so every claude --print subprocess + Task
# subagent fan-out inherits them. Phoenix runs at http://localhost:6006
# (docker container: phoenix). Disable by exporting QSHIP_OTEL_DISABLED=true.
if [ "${QSHIP_OTEL_DISABLED:-false}" != "true" ]; then
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
    export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
    export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
    export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
    export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4317}"
    export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
    export OTEL_METRIC_EXPORT_INTERVAL="${OTEL_METRIC_EXPORT_INTERVAL:-10000}"
    export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-qshipmaster}"
    # Capture prompts + tool I/O so subagent fan-out is inspectable in the UI.
    export OTEL_LOG_USER_PROMPTS="${OTEL_LOG_USER_PROMPTS:-1}"
    export OTEL_LOG_TOOL_DETAILS="${OTEL_LOG_TOOL_DETAILS:-1}"
    export OTEL_LOG_TOOL_CONTENT="${OTEL_LOG_TOOL_CONTENT:-1}"
fi

EPIC="${1:-}"
if [ -z "$EPIC" ]; then
    echo "Usage: $0 <EPIC-ID>" >&2
    exit 2
fi
if ! [[ "$EPIC" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "Invalid epic id: $EPIC" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qshipmaster-state.sh
source "$SCRIPT_DIR/qshipmaster-state.sh"

# Pre-flight gates from SKILL.md
QSHIP_HOOKS="${HOME}/.claude/skills/qship/hooks"
QSHIP_PERSIST_PATH="${QSHIP_PERSIST_PATH:-$QSHIP_HOOKS/qship-persist.sh}"

if [ ! -x "$QSHIP_PERSIST_PATH" ]; then
    echo "FATAL: qship-persist.sh missing at $QSHIP_PERSIST_PATH" >&2
    exit 10
fi
for f in require-pipeline-complete.sh require-phase3-evidence.sh; do
    if [ ! -f "$QSHIP_HOOKS/$f" ]; then
        echo "FATAL: $QSHIP_HOOKS/$f missing — apply post-{{JIRA_PROJECT_KEY}}-EX01 patches first" >&2
        exit 10
    fi
done

# pyenv shims if available (post-patch §8)
if [ -d "$HOME/.pyenv/shims" ]; then
    export PATH="$HOME/.pyenv/shims:$PATH"
fi

# Default GitHub host = {{COMPANY_SLUG}} enterprise
export GH_HOST="${GH_HOST:-{{GH_HOST}}}"

# Auto-launch remote-debug Chrome for Phase 3 chrome-devtools-attach MCP.
# Idempotent: skips if :9222 is already responding. Opt-out via QSHIP_SKIP_CHROME=true.
# Profile is dedicated (~/.cache/chrome-devtools-mcp-profile) so it doesn't
# touch the user's main browser. Logged-in state persists across restarts
# because the user-data-dir is fixed. The MCP server entry in ~/.claude.json
# (chrome-devtools-attach → --browser-url=http://127.0.0.1:9222) wires every
# `claude --print` subprocess to this Chrome.
# Auto-detect concurrent qshipmaster runs. If another orchestrator is already
# running for a DIFFERENT epic, the chrome-devtools-attach Chrome profile is a
# shared resource (single user-data-dir, single port 9222) — two epics' Phase 3
# subagents would stomp on each other's tabs/storage. Auto-skip Chrome launch
# and let this run fall back to Playwright MCP (fresh per-session Chromium).
# Explicit QSHIP_SKIP_CHROME=true still wins; this only kicks in when unset.
_other_qship=$(pgrep -f "qshipmaster-run.sh " 2>/dev/null | grep -v "^$$\$" | head -1 || true)
if [ -n "$_other_qship" ] && [ "${QSHIP_SKIP_CHROME:-}" = "" ]; then
    _other_epic=$(ps -p "$_other_qship" -o command= 2>/dev/null | awk '{print $NF}')
    if [ "$_other_epic" != "$EPIC" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] another qshipmaster running for $_other_epic (pid=$_other_qship) — auto-setting QSHIP_SKIP_CHROME=true to avoid profile contention"
        export QSHIP_SKIP_CHROME=true
    fi
fi

if [ "${QSHIP_SKIP_CHROME:-false}" != "true" ]; then
    if ! curl -sf --max-time 2 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
        CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        CHROME_PROFILE="$HOME/.cache/chrome-devtools-mcp-profile"
        if [ -x "$CHROME_BIN" ]; then
            mkdir -p "$CHROME_PROFILE"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] launching remote-debug Chrome on :9222 (profile=$CHROME_PROFILE)"
            nohup "$CHROME_BIN" \
                --remote-debugging-port=9222 \
                --user-data-dir="$CHROME_PROFILE" \
                > /tmp/chrome-devtools-mcp.log 2>&1 &
            disown
            # Brief wait for DevTools port to bind. Don't block forever — if Chrome
            # fails to come up, subprocesses fall back to Playwright MCP gracefully.
            for i in 1 2 3 4 5; do
                sleep 1
                if curl -sf --max-time 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Chrome DevTools port ready"
                    break
                fi
            done
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Chrome binary not at $CHROME_BIN — Phase 3 will use Playwright fallback"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Chrome :9222 already running — reusing"
    fi
fi

# TCC pre-flight: detect macOS permission popup stalls in <60s instead of
# letting them eat 30+ min of Phase 3 stream-json hang time. Fails-fast with
# clear remediation instructions if Playwright/Chrome can't spawn. Bypassed
# via QSHIP_SKIP_TCC_PREFLIGHT=true for headless CI.
TCC_PREFLIGHT="$SCRIPT_DIR/qshipmaster-tcc-preflight.sh"
if [ -x "$TCC_PREFLIGHT" ] && [ "${QSHIP_SKIP_TCC_PREFLIGHT:-false}" != "true" ]; then
    if ! "$TCC_PREFLIGHT"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] HALT: TCC pre-flight failed — see message above. Set QSHIP_SKIP_TCC_PREFLIGHT=true to bypass (Phase 3 will likely stall)."
        exit 11
    fi
fi

MAX_WAVE_ITERS="${MAX_WAVE_ITERS:-240}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_FIX_ITERS="${MAX_FIX_ITERS:-3}"
# Stuck-progress detector: if `tickets_pending` doesn't change for this many
# consecutive polls, halt the wave with a stall error instead of waiting out
# MAX_WAVE_ITERS. Mirrors Huntley's "fix_plan repetitive → discard & regenerate"
# anti-pattern guard from ghuntley.com/ralph.
STALL_POLLS="${STALL_POLLS:-30}"
REPO_ROOT="${REPO_ROOT:-{{CODEBASE_ROOT}}}"
WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
LOG_DIR=""

log() {
    local msg="[$(ts)] $*"
    echo "$msg"
    [ -n "$LOG_DIR" ] && echo "$msg" >> "$LOG_DIR/run.log" || true
}

# 1. Plan ----------------------------------------------------------------
"$SCRIPT_DIR/qshipmaster-plan.sh" "$EPIC"

EPIC_DIR=$(state_dir "$EPIC")
LOG_DIR="$EPIC_DIR/logs"
mkdir -p "$LOG_DIR"

CURRENT_STATUS=$(state_get "$EPIC" '.status')
if [ "$CURRENT_STATUS" = "shipped" ]; then
    log "epic $EPIC already shipped:"
    state_get "$EPIC" '.pr_url_per_repo | to_entries[] | "  \(.key): \(.value)"'
    exit 0
fi
if [ "$CURRENT_STATUS" = "error" ]; then
    log "epic $EPIC is in error state. Diagnosis:"
    state_get "$EPIC" '.error // "unknown"'
    exit 4
fi

EPIC_BRANCH=$(state_get "$EPIC" '.epic_branch')
BASE_BRANCH=$(state_get "$EPIC" '.base_branch')
REPOS=(); while IFS= read -r line; do REPOS+=("$line"); done < <(state_get "$EPIC" '.repos[]')
WAVE_COUNT=$(state_get "$EPIC" '.waves | length')

log "starting qshipmaster for $EPIC: $WAVE_COUNT wave(s), repos=[${REPOS[*]}], epic_branch=$EPIC_BRANCH"

# 2. Per-wave loop -------------------------------------------------------
for WAVE_N in $(seq 1 "$WAVE_COUNT"); do
    IDX=$((WAVE_N - 1))
    WAVE_STATUS=$(state_get "$EPIC" ".waves[$IDX].status")
    if [ "$WAVE_STATUS" = "shipped" ]; then
        log "wave $WAVE_N already shipped — skipping"
        continue
    fi
    if [ "$WAVE_STATUS" = "deferred" ]; then
        reason=$(state_get "$EPIC" ".waves[$IDX].deferred_reason // \"(no reason given)\"")
        log "wave $WAVE_N DEFERRED — skipping (reason: $reason). Tickets remain on their per-ticket branches for a follow-up epic."
        continue
    fi

    WAVE_TICKETS=(); while IFS= read -r line; do WAVE_TICKETS+=("$line"); done < <(state_get "$EPIC" ".waves[$IDX].tickets[]")
    log "wave $WAVE_N: tickets=[${WAVE_TICKETS[*]}], status=$WAVE_STATUS"

    # 2a. Determine BASE_BRANCH for this wave (Wave 1 = develop, Wave N>1 = epic_branch).
    if [ "$WAVE_N" -gt 1 ]; then
        WAVE_BASE="$EPIC_BRANCH"
    else
        WAVE_BASE="$BASE_BRANCH"
    fi
    log "wave $WAVE_N base branch = $WAVE_BASE"

    # 2b. Spawn qship-persist.sh per ticket (skip if already PASSED).
    if [ "$WAVE_STATUS" = "pending" ] || [ "$WAVE_STATUS" = "in_flight" ]; then
        for ticket in "${WAVE_TICKETS[@]}"; do
            local_log="$LOG_DIR/$ticket-persist.log"
            check_log="$LOG_DIR/$ticket-qshipcheck.log"

            # Skip if already passed — atomic flag file written by
            # qship-persist.sh::ticket_is_complete (post-{{JIRA_PROJECT_KEY}}-EX01 patch §9).
            if [ -f "$WORKTREE_ROOT/$ticket/qshipcheck-PASSED.flag" ]; then
                log "  $ticket: already PASSED (flag present) — skipping spawn"
                continue
            fi

            # Skip if a persist process is already running for this ticket
            if pgrep -f "qship-persist.sh $ticket\b" >/dev/null 2>&1; then
                log "  $ticket: persist process already running — skipping spawn"
                continue
            fi

            log "  $ticket: spawning qship-persist.sh in EPIC_MODE"
            # Wrap the worker in `setsid` so it becomes the leader of its own
            # process group. On stall HALT we then `kill -- -PGID` for atomic
            # tree cleanup (claude grandchild + any MCP server children) — see
            # https://morningcoffee.io/killing-a-process-and-all-of-its-descendants
            # If setsid is missing (rare on macOS without coreutils), fall back
            # to plain nohup; the multi-pattern pkill cleanup still works.
            setsid_bin="$(command -v setsid || true)"
            if [ -n "$setsid_bin" ]; then
                EPIC_MODE=true \
                EPIC_ID="$EPIC" \
                EPIC_STATE_FILE="$(state_path "$EPIC")" \
                EPIC_BASE_BRANCH="$WAVE_BASE" \
                    "$setsid_bin" bash "$QSHIP_PERSIST_PATH" "$ticket" \
                    > "$local_log" 2>&1 &
            else
                EPIC_MODE=true \
                EPIC_ID="$EPIC" \
                EPIC_STATE_FILE="$(state_path "$EPIC")" \
                EPIC_BASE_BRANCH="$WAVE_BASE" \
                    nohup bash "$QSHIP_PERSIST_PATH" "$ticket" \
                    > "$local_log" 2>&1 &
            fi
            disown $! 2>/dev/null || true
        done

        state_set "$EPIC" ".waves[$IDX].status" "in_flight"
    fi

    # 2c. Barrier — poll until every ticket in the wave reports PASSED.
    # Completion signal = atomic flag file at $WORKTREE_ROOT/<ticket>/qshipcheck-PASSED.flag
    # (written by qship-persist.sh::ticket_is_complete). Log-grep was fragile —
    # one log-format change broke the barrier; the flag file is the discrete
    # signal, the log remains as evidence.
    iter=0
    last_pending_signature=""
    stall_count=0
    while [ "$iter" -lt "$MAX_WAVE_ITERS" ]; do
        iter=$((iter + 1))
        passed=0
        blocked=0
        running=0
        passed_list=()
        pending_list=()
        for ticket in "${WAVE_TICKETS[@]}"; do
            if [ -f "$WORKTREE_ROOT/$ticket/qshipcheck-PASSED.flag" ]; then
                passed=$((passed + 1))
                passed_list+=("$ticket")
            elif grep -q "GAVE UP after" "$LOG_DIR/$ticket-persist.log" 2>/dev/null; then
                blocked=$((blocked + 1))
                pending_list+=("$ticket(BLOCKED)")
            else
                running=$((running + 1))
                pending_list+=("$ticket")
            fi
        done

        # Persist progress
        if [ "${#passed_list[@]}" -eq 0 ]; then passed_json='[]'; else passed_json=$(printf '%s\n' "${passed_list[@]}" | jq -R . | jq -s .); fi
        if [ "${#pending_list[@]}" -eq 0 ]; then pending_json='[]'; else pending_json=$(printf '%s\n' "${pending_list[@]}" | jq -R . | jq -s .); fi
        state_set "$EPIC" ".waves[$IDX].tickets_passed" "$passed_json"
        state_set "$EPIC" ".waves[$IDX].tickets_pending" "$pending_json"

        log "  wave $WAVE_N poll $iter: passed=$passed, running=$running, blocked=$blocked"

        if [ "$blocked" -gt 0 ]; then
            log "HALT: wave $WAVE_N has $blocked blocked ticket(s). Inspect logs:"
            for t in "${pending_list[@]}"; do
                log "  $LOG_DIR/${t%%(*}-persist.log"
            done
            state_set "$EPIC" '.status' 'blocked'
            state_set "$EPIC" '.error' "wave $WAVE_N has blocked tickets: ${pending_list[*]}"
            exit 7
        fi

        if [ "$running" -eq 0 ] && [ "$passed" = "${#WAVE_TICKETS[@]}" ]; then
            log "wave $WAVE_N: all ${#WAVE_TICKETS[@]} ticket(s) PASSED qshipcheck"
            break
        fi

        # Stuck-progress detector — Huntley's "fix_plan repetitive" guard.
        # If pending list hasn't shifted for STALL_POLLS consecutive polls,
        # halt instead of burning the rest of MAX_WAVE_ITERS waiting on a
        # ticket that's making no forward progress.
        current_signature="$(printf '%s\n' "${pending_list[@]}" | sort | sha1sum | awk '{print $1}')"
        # Forward-progress probe: if any pending worker's persist log or any
        # of its iter logs has been modified within the last STALL_POLLS
        # minutes, the worker is alive and producing output — reset stall
        # count even though the qshipcheck-PASSED.flag hasn't landed yet.
        # This prevents false-positive stalls on large tickets where iter 1
        # legitimately runs >20 min (timeout fires, persist respawns iter 2).
        log_progress_seen=0
        for stuck in "${pending_list[@]}"; do
            stuck_ticket="${stuck%%(*}"
            for f in "$LOG_DIR/${stuck_ticket}-persist.log" {{STATE_ROOT}}/persist-logs/${stuck_ticket}-iter-*.log; do
                [ -f "$f" ] || continue
                if [ -n "$(find "$f" -mmin -"$STALL_POLLS" 2>/dev/null)" ]; then
                    log_progress_seen=1
                    break 2
                fi
            done
        done
        if [ "$log_progress_seen" -eq 1 ]; then
            stall_count=0
            last_pending_signature="$current_signature"
        elif [ "$current_signature" = "$last_pending_signature" ] && [ "${#pending_list[@]}" -gt 0 ]; then
            stall_count=$((stall_count + 1))
            if [ "$stall_count" -ge "$STALL_POLLS" ]; then
                log "HALT: wave $WAVE_N stalled — pending=[${pending_list[*]}] unchanged for $stall_count polls"
                # Clean up wedged worker process trees so they don't sit as
                # zombies eating an opus[1m] session — without this, a stuck
                # `claude --print` child (and its persist parent) lingers
                # forever after the orchestrator exits. Workers were spawned
                # under `setsid` so each is its own pgroup leader; killing the
                # negative PID atomically takes down the persist parent + the
                # claude grandchild + any MCP-server descendants in one shot.
                # Multi-pattern pkill is the fallback for the no-setsid path.
                for stuck in "${pending_list[@]}"; do
                    stuck_ticket="${stuck%%(*}"
                    # Find the persist PID for this ticket and kill its pgroup.
                    persist_pid=$(pgrep -f "qship-persist.sh $stuck_ticket\b" | head -1)
                    if [ -n "$persist_pid" ]; then
                        pgid=$(ps -o pgid= -p "$persist_pid" 2>/dev/null | tr -d ' ')
                        if [ -n "$pgid" ] && [ "$pgid" != "$$" ]; then
                            kill -KILL -- "-$pgid" 2>/dev/null || true
                        fi
                    fi
                    # Belt-and-braces fallback in case pgroup kill missed.
                    pkill -KILL -f "qship-persist.sh $stuck_ticket\b" 2>/dev/null || true
                    pgrep -f "claude .* /qship(check)? $stuck_ticket" 2>/dev/null | xargs kill -KILL 2>/dev/null || true
                done
                state_set "$EPIC" '.status' 'blocked'
                state_set "$EPIC" '.error' "wave $WAVE_N stalled: no forward progress in $stall_count polls; pending=${pending_list[*]}"
                exit 11
            fi
        else
            stall_count=0
            last_pending_signature="$current_signature"
        fi

        sleep "$POLL_INTERVAL"
    done

    if [ "$running" -gt 0 ] || [ "$passed" -lt "${#WAVE_TICKETS[@]}" ]; then
        log "HALT: wave $WAVE_N exceeded MAX_WAVE_ITERS=$MAX_WAVE_ITERS"
        state_set "$EPIC" '.status' 'blocked'
        state_set "$EPIC" '.error' "wave $WAVE_N timeout"
        exit 8
    fi

    # 2d. Merge wave into consolidated epic branch
    log "merging wave $WAVE_N into $EPIC_BRANCH"
    if ! "$SCRIPT_DIR/qshipmaster-merge-wave.sh" "$EPIC" "$WAVE_N"; then
        log "HALT: wave $WAVE_N merge failed. See $EPIC_DIR/wave-${WAVE_N}-conflict.json"
        state_set "$EPIC" '.status' 'blocked'
        state_set "$EPIC" '.error' "wave $WAVE_N merge conflict"
        exit 5
    fi

    # 2e. Wave-level Phase 2 review + Phase 3 E2E batch — runs ONCE on the
    # merged wave diff (instead of N times, one per ticket inside /qship).
    # Workers in EPIC_MODE shipped Phase-1-only; this batch runs review
    # subagents (7.5 / 8 / 9 / 10) + Playwright E2E across the whole wave.
    # ~10x fewer subagent dispatches for epics with overlapping surfaces.
    log "wave $WAVE_N: dispatching wave-level Phase 2 review + Phase 3 E2E batch"
    {
        echo "=== Wave $WAVE_N batch review ==="
        echo "Date: $(ts)"
        echo "Tickets: ${WAVE_TICKETS[*]}"
        echo "Repos: ${REPOS[*]}"
        echo "Epic branch: $EPIC_BRANCH"
        echo ""
    } > "$EPIC_DIR/wave-${WAVE_N}-phase23-evidence.md"

    # Re-read repos from state.json — the in-memory REPOS array can be stale if
    # state.json was patched mid-run (e.g. repo-name fix). Without this reload,
    # `cd $repo_dir` silently fails and the entire batch (Phase 2 review +
    # Phase 3 E2E) is skipped — see {{JIRA_PROJECT_KEY}}-EX14 Phase 3 skip incident.
    DISPATCH_REPOS=(); while IFS= read -r line; do DISPATCH_REPOS+=("$line"); done < <(state_get "$EPIC" '.repos[]')
    dispatched_count=0
    for repo in "${DISPATCH_REPOS[@]}"; do
        repo_dir="$REPO_ROOT/$repo"
        if [ ! -d "$repo_dir/.git" ]; then
            log "  wave $WAVE_N batch review: $repo not found at $repo_dir — SKIPPING (Phase 2/3 will not run for this repo)"
            continue
        fi
        # Only review repos that actually got commits in this wave.
        cd "$repo_dir" >/dev/null 2>&1 || { log "  wave $WAVE_N batch review: cd $repo_dir failed — SKIPPING"; continue; }
        git checkout "$EPIC_BRANCH" >/dev/null 2>&1 || { log "  wave $WAVE_N batch review: checkout $EPIC_BRANCH in $repo failed — SKIPPING"; continue; }
        wave_diff_size=$(git log --oneline "develop..$EPIC_BRANCH" -- 2>/dev/null | wc -l | tr -d ' ')
        [ "$wave_diff_size" -eq 0 ] && continue
        dispatched_count=$((dispatched_count + 1))
        log "  wave $WAVE_N batch review: $repo ($wave_diff_size commits since develop)"

        ticket_summaries=""
        for t in "${WAVE_TICKETS[@]}"; do
            if [ -f "{{STATE_ROOT}}/worktrees/$t/phase1-summary.md" ]; then
                ticket_summaries="$ticket_summaries"$'\n\n=== '"$t"' ==='$'\n'"$(cat "{{STATE_ROOT}}/worktrees/$t/phase1-summary.md" 2>/dev/null)"
            fi
        done

        wave_review_log="$EPIC_DIR/logs/wave-${WAVE_N}-${repo}-batch-review.log"
        # Wrap in `timeout` so a hung MCP tool (Playwright handle lost, etc.)
        # can't burn the whole epic. Default 4h; override via
        # QSHIP_BATCH_REVIEW_TIMEOUT_SEC. {{JIRA_PROJECT_KEY}}-EX07 wave-2 {{PRIMARY_REPO_NAME}} hung at 0.2%
        # CPU for 11h before manual kill — that's the failure this guards.
        _batch_timeout="${QSHIP_BATCH_REVIEW_TIMEOUT_SEC:-14400}"
        _timeout_bin="$(command -v timeout || command -v gtimeout || timeout)"
        "$_timeout_bin" --kill-after=30s "$_batch_timeout" \
        claude --print --dangerously-skip-permissions \
            --output-format stream-json --verbose \
            --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,Task,TodoWrite,WebSearch,WebFetch' \
            --model "${QSHIP_PHASE2_REVIEW_MODEL:-opus[1m]}" \
            --effort "${QSHIP_PHASE2_REVIEW_EFFORT:-high}" \
            --append-system-prompt 'WAVE BATCH REVIEW MODE. Workers shipped Phase-1-only commits across multiple tickets that have been merged into the epic branch. Run ONE consolidated review covering all tickets together. CRITICAL: BEFORE you return your final assistant message, you MUST yourself (not a subagent) Write the evidence file at the path given in the user prompt, and that file MUST literally contain the four marker words qsimplify, qcheck, qbug, qbcheck — these are how the orchestrator validates completion. If you delegate the review to subagents, you remain responsible for synthesizing their findings into the evidence file with the marker words present. Do NOT return until the file is written.' \
            "Wave $WAVE_N batch review for repo $repo on branch $EPIC_BRANCH (cwd: $REPO_ROOT/$repo).

Tickets in this wave: ${WAVE_TICKETS[*]}
Per-ticket Phase-1 summaries:$ticket_summaries

Diff to review: \`git diff develop..$EPIC_BRANCH\` in $repo_dir

Run these qship subagents on the merged wave diff (not per ticket — once for the whole wave):

PHASE 2:
1. /qsimplify (Step 7.5) — flag unused / over-engineered code introduced by this wave.
2. /qcheck (Step 8) — production-readiness review.
3. /qbug (Step 9) — bug hunt covering security, race conditions, edge cases, silent failures, root-cause traceability.
4. /qbcheck (Step 10) — validate findings from #2 and #3, drop false positives.
5. Fix every CRITICAL or HIGH finding with explicit edits and a commit. Do NOT fix LOW/INFO findings unless trivially safe.
6. Verification gate: \`black --check\`, \`isort --check-only\`, \`flake8\`, \`pytest tests/\` must all pass on the merged branch. If any fail, fix and re-run until green.

PHASE 3 (E2E) — HARD REQUIREMENT (I1 invariant, hook-enforced):

** /qe2etest IS THE ONLY ACCEPTABLE SOURCE OF PHASE 3 EVIDENCE **
** pytest, TestClient, raw curl, psql output — ALL FORBIDDEN as Phase 3.  **
** They are Phase 2 verification only. Citing them in your Phase 3 section **
** WILL be rejected by the validator hook (require-qe2etest-evidence.sh).  **

The evidence file you must populate is at this EXACT path (memorize, do not abbreviate, do not shorten, do not change ANY character):

  {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX06/wave-\${WAVE_N}-phase23-evidence.md

Spelled out: the directory is {{STATE_ROOT}}/epic-<EPIC_ID>/ (where <EPIC_ID> is literally the epic Jira ID like {{JIRA_PROJECT_KEY}}-EX06), and the file is wave-<N>-phase23-evidence.md (note "phase23" not "phase3" — the "2" is part of the filename). DO NOT write to wave-N-evidence.md or wave3-evidence.md or any shortened variant. The orchestrator's validator hook greps for content at this exact path; any other path is invisible to it and the wave will HALT.

Procedure:

7. Spin up the local stack via /qspinuplocal (it handles the load_dotenv quirks, port conflicts, DEV_TENANT_ID injection). If /qspinuplocal is unavailable, fall back to manual detached spin-up:
     nohup env DEV_MODE=true python serve.py > /tmp/server-wave-\${WAVE_N}.log 2>&1 < /dev/null & disown
   Poll readiness: \`for i in {1..30}; do curl -sf http://localhost:8001/health >/dev/null && break; sleep 2; done\`. If no health 200 within 60s, document in wave-\${WAVE_N}-blocked.md and surface — do NOT proceed with a partial stack.

8. Invoke the /qe2etest skill via the Skill tool: \`Skill(skill="qe2etest")\`. The skill itself drives the scenario execution against the running local stack. Capture its FULL output via tee to {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX06/wave-\${WAVE_N}-qe2etest.log. Per-scenario artifacts (curl response bodies, Playwright screenshots, psql verify blocks) go under {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX06/wave-\${WAVE_N}-qe2etest-artifacts/.

   HEARTBEAT — every 5 minutes, touch {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX06/wave-\${WAVE_N}-heartbeat.txt with the current scenario name. Supervisor uses this file's mtime to distinguish "claude blocked in long pytest" from "claude actually hung".

9. AFTER /qe2etest returns, append a section to wave-\${WAVE_N}-phase23-evidence.md with the EXACT LITERAL heading:

   ## Phase 3 — /qe2etest evidence

   That heading is required verbatim, em-dash and all. "## Phase 3" alone, "## Phase 3 E2E", "## Phase 3 Tests" — ALL REJECTED. The validator greps for this exact string.

   Inside that section, provide a markdown TABLE with rows like this:

   | ID | Method | Artifact path | Verdict |
   |---|---|---|---|
   | S1 | qe2etest:GET /api/v1/policies/peers | {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX06/wave-${WAVE_N}-qe2etest-artifacts/s1-curl.txt | PASS |
   | S2 | qe2etest:Playwright RecordList badge render | {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX06/wave-${WAVE_N}-qe2etest-artifacts/s2-screenshot.png | PASS |

   Critical: the "Method" column of EACH row MUST start with \`qe2etest:\` (or \`/qe2etest\`). Rows that start with \`pytest:\`, \`curl:\` (without the qe2etest: prefix), \`psql:\`, \`TestClient:\` will trigger the banlist rejection — the validator sees zero qe2etest rows and refuses the file.

   You MAY mention pytest/curl/psql inside an artifact body if /qe2etest itself used them — but the row's Method column MUST start with qe2etest: to mark that as a /qe2etest-driven verification.

   Include a \`Verdict: SHIPPABLE\` summary line at the bottom of the section if all rows passed. Per /qe2etest Step 4.5 (fix-and-retest loop), if a scenario FAILs, fix it on the worktree (banlist: no pytest.skip, no assertion weakening, no test deletion), retest that scenario, then continue. MAX_FIX_ITERS=3 per scenario.

10. ESCAPE HATCH (only if the wave's merged diff genuinely touches ZERO FastAPI routes / *.tsx / *.jsx / fetchJson() calls / endpoint-reachable alembic columns): instead of running /qe2etest, write the EXACT line in the Phase 3 section:

   no qe2etest surface: <one sentence citing the diff scope, ≥10 chars>

   The validator cross-checks this rationale against \`git diff develop..HEAD\` and REJECTS the claim if the diff actually touches those surface markers. Don't try this for a wave with FastAPI changes — the contradiction is detected and the wave HALTs.

PROBABILISTIC COMPLIANCE — Re-run on Critical:
After the FIRST qbcheck pass, count how many CRITICAL findings are kept as MUST FIX (not demoted to false-positive). If that count is >= 2, you MUST run the qsimplify/qcheck/qbug/qbcheck pipeline a SECOND time with a different seed phrasing (e.g. "review for production deployment safety, not feature correctness") on the same merged diff. Compare the two runs:
- Findings flagged CRITICAL by BOTH runs → keep as MUST FIX (high confidence).
- Findings flagged by only ONE run → keep as MUST FIX anyway (conservative — false negatives are more dangerous than false positives at the wave-batch boundary), AND list them in a new \`## Re-run delta\` section of the evidence file with which run found them.
- If count < 2 CRITICAL after first pass → no re-run needed; write \`re-run decision: single-pass sufficient (<2 CRITICAL findings)\` to $EPIC_DIR/wave-${WAVE_N}-rerun-decision.txt.
- If re-run executed → write \`re-run decision: executed (N CRITICAL in first pass, M agreed across runs)\` to the same file.
This file's existence is checked by the supervisor — missing file means re-run logic was skipped and the wave is rejected at FINAL VERIFICATION.

REQUIRED EVIDENCE — append to $EPIC_DIR/wave-${WAVE_N}-phase23-evidence.md a Phase 2 review checklist with these EXACT marker words (the require-pipeline-complete.sh hook greps for them — missing markers = pipeline-blocked):

## Phase 2 review checklist
- qsimplify (Step 7.5): <N findings>, <M fixed inline>, <K demoted by qbcheck>
- qcheck (Step 8): <N findings across 3 agents>, <M CRITICAL/HIGH fixed>
- qbug (Step 9): <N findings across 5 agents>, <M CRITICAL/HIGH fixed>
- qbcheck (Step 10): <K false positives demoted>, <N kept as MUST FIX>
- Step 11 fixes committed: <git sha list, or 'none — no findings to fix'>
- Step 11.5 verification gate: black=PASS|FAIL, isort=PASS|FAIL, flake8=PASS|FAIL, pytest=PASS|FAIL

## Phase 3 evidence
<one row per AC scenario with curl/click/SQL artifact>

NON-NEGOTIABLE:
- No pytest.skip / xfail / assert True / try-except: pass / # noqa muting on real failures.
- If a finding genuinely belongs to a different wave or is environmental (e.g. {{PRIMARY_REPO_NAME}} unavailable), document in $EPIC_DIR/wave-${WAVE_N}-blocked.md and exit non-zero.
- Commit fixes onto $EPIC_BRANCH with explicit file lists. Do NOT push, do NOT open PRs (orchestrator handles deliver).
- The four marker words 'qsimplify', 'qcheck', 'qbug', 'qbcheck' MUST appear literally in the evidence file. The orchestrator post-checks for them and HALTS the run if missing." \
            > "$wave_review_log" 2>&1 || true
        cd /tmp >/dev/null 2>&1
    done

    # Sanity gate: if no repo was actually dispatched, OR if the evidence file
    # didn't grow a Phase 3 section, the batch silently no-op'd. Refuse to mark
    # the wave shipped — that's the {{JIRA_PROJECT_KEY}}-EX14 Phase 3 skip bug.
    if [ "$dispatched_count" -eq 0 ]; then
        log "HALT: wave $WAVE_N batch dispatch reached zero repos. State.json repos=[${DISPATCH_REPOS[*]}] — none resolved to a git dir under $REPO_ROOT. Phase 2/3 cannot run."
        state_set "$EPIC" '.error' "wave $WAVE_N: zero repos dispatched (repo-name mismatch?)"
        exit 1
    fi
    # Phase 2 review marker check — the dispatch prompt requires the worker to
    # write a checklist with these exact words. Missing any of them means the
    # corresponding subagent did not run (silent skip), which is the gap that
    # bit {{JIRA_PROJECT_KEY}}-EX14. require-pipeline-complete.sh also blocks on these post-merge,
    # but we want a louder, earlier failure inside the orchestrator itself.
    p2_missing=()
    for marker in qsimplify qcheck qbug qbcheck; do
        if ! grep -qi "$marker" "$EPIC_DIR/wave-${WAVE_N}-phase23-evidence.md" 2>/dev/null; then
            p2_missing+=("$marker")
        fi
    done
    if [ "${#p2_missing[@]}" -gt 0 ]; then
        log "HALT: wave $WAVE_N batch evidence missing Phase 2 review markers: ${p2_missing[*]}. The dispatched worker did not run those subagents. See $EPIC_DIR/logs/wave-${WAVE_N}-*-batch-review.log for the worker transcript."
        state_set "$EPIC" '.error' "wave $WAVE_N: Phase 2 markers missing (${p2_missing[*]})"
        exit 1
    fi

    # I1 invariant — /qe2etest must be the ONLY accepted Phase 3 evidence.
    # validate_qe2etest_evidence enforces:
    #   (a) literal "## Phase 3 — /qe2etest evidence" heading
    #   (b) /qe2etest invocation + PASS verdict OR "no qe2etest surface:" rationale
    #   (c) banlist: pytest/TestClient/psql/curl rejected as primary Phase 3 method
    #   (d) when claimed "no surface", cross-check against the wave's merged diff
    # Source the lib once (idempotent).
    QSHIP_HOOKS_DIR="${HOME}/.claude/skills/qship/hooks"
    if [ -f "$QSHIP_HOOKS_DIR/qship-evidence-lib.sh" ]; then
        # shellcheck source={{USER_HOME}}/.claude/skills/qship/hooks/qship-evidence-lib.sh
        source "$QSHIP_HOOKS_DIR/qship-evidence-lib.sh"
        wave_diff_ref="${BASE_BRANCH}..HEAD"
        wave_repo_dir="$REPO_ROOT/${REPOS[0]}"
        if ! validate_qe2etest_evidence \
                "$EPIC_DIR/wave-${WAVE_N}-phase23-evidence.md" \
                "wave $WAVE_N" \
                "$wave_diff_ref" \
                "$wave_repo_dir" \
                2>"$EPIC_DIR/wave-${WAVE_N}-qe2etest-validator.err"; then
            err=$(cat "$EPIC_DIR/wave-${WAVE_N}-qe2etest-validator.err" 2>/dev/null || echo "validation failed")
            log "HALT: wave $WAVE_N evidence fails I1 (/qe2etest enforcement): $err"
            state_set "$EPIC" '.error' "wave $WAVE_N: I1 violation — $err"
            exit 1
        fi
    else
        log "WARN: $QSHIP_HOOKS_DIR/qship-evidence-lib.sh missing — skipping I1 /qe2etest validation (legacy fallback)"
    fi

    state_set "$EPIC" ".waves[$IDX].status" "shipped"
    state_set "$EPIC" ".waves[$IDX].phase2_passed" "wave_batch"
    state_set "$EPIC" ".waves[$IDX].wave_phase3_evidence" "$EPIC_DIR/wave-${WAVE_N}-phase23-evidence.md"
    log "wave $WAVE_N complete (batch Phase 2 + Phase 3 dispatched, repos=$dispatched_count)"
    continue
    # legacy per-wave Phase 2 lint/test loop (retained below the `continue`
    # for compatibility with QSHIP_PER_WAVE_PHASE2=true override callers).
    log "running wave $WAVE_N Phase 2 (lint + pytest)..."
    fix_iter=0
    phase2_pass=0
    while [ "$fix_iter" -lt "$MAX_FIX_ITERS" ]; do
        fix_iter=$((fix_iter + 1))
        all_green=1
        for repo in "${REPOS[@]}"; do
            repo_dir="$REPO_ROOT/$repo"
            [ -d "$repo_dir/.git" ] || continue
            (
                cd "$repo_dir" && git checkout "$EPIC_BRANCH" >/dev/null 2>&1
                evidence_log="$EPIC_DIR/wave-${WAVE_N}-${repo}-phase2.log"
                {
                    echo "=== black ==="
                    black --check . 2>&1 || echo "BLACK FAILED"
                    echo "=== isort ==="
                    isort --check-only . 2>&1 || echo "ISORT FAILED"
                    echo "=== flake8 ==="
                    flake8 2>&1 || echo "FLAKE8 FAILED"
                    echo "=== pytest ==="
                    pytest tests/ -v --tb=short 2>&1 || echo "PYTEST FAILED"
                } > "$evidence_log" 2>&1
                if grep -qE 'FAILED|errors? in' "$evidence_log"; then exit 1; fi
            ) || all_green=0
        done

        if [ "$all_green" -eq 1 ]; then
            phase2_pass=1
            break
        fi

        log "  wave $WAVE_N Phase 2 iter $fix_iter: failures detected — dispatching fix worker"

        # Dispatch a headless fix-only worker. The worker reads the latest
        # phase2 logs and commits fixes onto $EPIC_BRANCH.
        for repo in "${REPOS[@]}"; do
            evidence_log="$EPIC_DIR/wave-${WAVE_N}-${repo}-phase2.log"
            [ -s "$evidence_log" ] || continue
            grep -qE 'FAILED|error' "$evidence_log" || continue
            claude --print --dangerously-skip-permissions \
                --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,Task,TodoWrite' \
                --model "${QSHIP_FIX_MODEL:-opus[1m]}" \
                --effort "${QSHIP_FIX_EFFORT:-medium}" \
                "Wave $WAVE_N Phase 2 review failed for repo $repo on branch $EPIC_BRANCH (cwd: $REPO_ROOT/$repo). Read $evidence_log, fix every reported failure (black formatting, isort imports, flake8 lints, failing pytest tests). Before fixing, READ ~/.claude/skills/qshipmaster/AGENTS.md (if it exists) for prior wave-fix learnings — those rules came from past failures. Commit fixes onto $EPIC_BRANCH with explicit file lists (NOT git add -A — post-patch §7). Do not create PRs, do not push. EPIC_MODE=true.

NON-NEGOTIABLE — DO NOT IMPLEMENT PLACEHOLDER OR SIMPLE IMPLEMENTATIONS. Specifically forbidden as 'fixes':
  - pytest.skip / pytest.xfail / @pytest.mark.skip on the failing test
  - replacing assertions with 'assert True' or weaker checks
  - deleting the failing test
  - try/except: pass to suppress the error
  - editing # noqa / # type: ignore to mute lints rather than fixing the underlying issue
  - stubbing out the function under test to return a hardcoded value
If a test is genuinely flaky, environment-bound, or the failure points to a real bug that's out-of-scope for this wave's tickets, STOP. Write the diagnosis (file:line, root cause, why it's out of scope) to $EPIC_DIR/wave-${WAVE_N}-blocked.md and exit non-zero — the orchestrator will halt and surface to the user. Faking a green pipeline is a worse outcome than halting. (Source: Huntley, ghuntley.com/ralph)" \
                > "$EPIC_DIR/logs/wave-${WAVE_N}-${repo}-fix-iter-${fix_iter}.log" 2>&1 || true

            # Cross-epic learning — append root-cause + rule to AGENTS.md for
            # future epic runs to read. Pattern from ralph-zero. Best-effort:
            # don't fail the wave if learning extraction fails.
            EPIC_ROOT="${EPIC_ROOT:-{{STATE_ROOT}}-epic}" \
                bash "$SCRIPT_DIR/qshipmaster-learn.sh" "$EPIC" "$WAVE_N" "$repo" "$fix_iter" \
                >> "$LOG_DIR/learn.log" 2>&1 || true
        done
    done

    if [ "$phase2_pass" -ne 1 ]; then
        log "HALT: wave $WAVE_N Phase 2 still failing after $MAX_FIX_ITERS fix iterations"
        state_set "$EPIC" '.status' 'blocked'
        state_set "$EPIC" '.error' "wave $WAVE_N Phase 2 unfixable"
        exit 9
    fi

    # 2f. Write wave-level Phase 3 evidence (consumed by post-patch §3 hook)
    {
        echo "# Wave $WAVE_N Phase 2/3 evidence — $EPIC"
        echo "Date: $(ts)"
        echo "Tickets: ${WAVE_TICKETS[*]}"
        echo ""
        for repo in "${REPOS[@]}"; do
            evidence_log="$EPIC_DIR/wave-${WAVE_N}-${repo}-phase2.log"
            [ -s "$evidence_log" ] || continue
            echo "## $repo"
            tail -40 "$evidence_log"
            echo ""
        done
    } > "$EPIC_DIR/wave-${WAVE_N}-phase3-evidence.md"

    state_set "$EPIC" ".waves[$IDX].status" "shipped"
    state_set "$EPIC" ".waves[$IDX].phase2_passed" "true"
    state_set "$EPIC" ".waves[$IDX].wave_phase3_evidence" "$EPIC_DIR/wave-${WAVE_N}-phase3-evidence.md"

    log "wave $WAVE_N complete"
done

# 3. Epic-level final pass — Phase 2 (lint + tests + cross-wave review) and
# Phase 3 (full E2E sweep) on the integrated epic diff. The wave-level batches
# already covered each wave's Phase 2/3 against its own merged diff; this
# final pass catches cross-wave interactions and serves as the single
# pre-deliver gate.
# Skip with QSHIP_EPIC_PHASE2=false (e.g. for dry-runs).
if [ "${QSHIP_EPIC_PHASE2:-true}" = "true" ]; then
    log "running epic-level Phase 2 (lint + pytest) on $EPIC_BRANCH"
    fix_iter=0
    phase2_pass=0
    while [ "$fix_iter" -lt "$MAX_FIX_ITERS" ]; do
        fix_iter=$((fix_iter + 1))
        all_green=1
        for repo in "${REPOS[@]}"; do
            repo_dir="$REPO_ROOT/$repo"
            [ -d "$repo_dir/.git" ] || continue
            (
                cd "$repo_dir" && git checkout "$EPIC_BRANCH" >/dev/null 2>&1
                evidence_log="$EPIC_DIR/epic-${repo}-phase2.log"
                {
                    echo "=== black ==="
                    black --check . 2>&1 || echo "BLACK FAILED"
                    echo "=== isort ==="
                    isort --check-only . 2>&1 || echo "ISORT FAILED"
                    echo "=== flake8 ==="
                    flake8 2>&1 || echo "FLAKE8 FAILED"
                    echo "=== pytest ==="
                    pytest tests/ -v --tb=short 2>&1 || echo "PYTEST FAILED"
                } > "$evidence_log" 2>&1
                if grep -qE 'FAILED|errors? in' "$evidence_log"; then exit 1; fi
            ) || all_green=0
        done
        if [ "$all_green" -eq 1 ]; then phase2_pass=1; break; fi
        log "  epic Phase 2 iter $fix_iter: failures detected — dispatching fix worker"
        for repo in "${REPOS[@]}"; do
            evidence_log="$EPIC_DIR/epic-${repo}-phase2.log"
            [ -s "$evidence_log" ] || continue
            grep -qE 'FAILED|error' "$evidence_log" || continue
            claude --print --dangerously-skip-permissions \
                --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,Task,TodoWrite' \
                --model "${QSHIP_FIX_MODEL:-opus[1m]}" \
                --effort "${QSHIP_FIX_EFFORT:-medium}" \
                "Epic Phase 2 review failed for repo $repo on branch $EPIC_BRANCH (cwd: $REPO_ROOT/$repo). Read $evidence_log, fix every reported failure (black, isort, flake8, pytest). Commit fixes onto $EPIC_BRANCH with explicit file lists. Do not create PRs, do not push. EPIC_MODE=true. NON-NEGOTIABLE: no pytest.skip/xfail, no assert True, no test deletion, no try/except: pass, no # noqa muting. If a failure is genuinely out-of-scope or environmental (e.g. requires a live server), write the diagnosis to $EPIC_DIR/epic-blocked.md and exit non-zero. Faking green is worse than halting." \
                > "$EPIC_DIR/logs/epic-${repo}-fix-iter-${fix_iter}.log" 2>&1 || true
        done
    done
    if [ "$phase2_pass" -ne 1 ]; then
        log "HALT: epic Phase 2 still failing after $MAX_FIX_ITERS fix iterations"
        state_set "$EPIC" '.status' 'blocked'
        state_set "$EPIC" '.error' "epic Phase 2 unfixable"
        exit 9
    fi
    log "epic Phase 2 PASSED"
fi

# 4. Final delivery ------------------------------------------------------
log "all waves shipped — invoking deliver"
"$SCRIPT_DIR/qshipmaster-deliver.sh" "$EPIC"

log "qshipmaster $EPIC complete"
state_get "$EPIC" '.pr_url_per_repo | to_entries[] | "  \(.key): \(.value)"'
