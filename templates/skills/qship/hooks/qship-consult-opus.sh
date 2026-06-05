#!/bin/bash
# qship-consult-opus.sh — advisor helper invoked by the Sonnet executor.
#
# This is the Bash-tool-based implementation of Anthropic's advisor pattern
# (https://claude.com/blog/the-advisor-strategy). The Sonnet executor running
# /qship calls this script via the Bash tool when it hits a decision that
# benefits from deeper reasoning (Phase 1 plan finalization, Phase 2 review
# subagents, complex bug fix root-cause). The script invokes Opus 4.7 in 1M
# context as a one-shot consultant, returns its verdict on stdout, and the
# executor continues with the task.
#
# Why this exists: Claude Code's --print headless mode doesn't yet expose the
# native API advisor tool (beta header advisor-tool-2026-03-01) directly. The
# Bash-helper pattern works today inside Claude Code and is functionally
# equivalent for our use case. When Claude Code GAs --enable-advisor, this
# script can be retired and the system prompt's advisor block becomes a no-op.
#
# Usage (from inside /qship, executor invokes via Bash tool):
#   bash ~/.claude/skills/qship/hooks/qship-consult-opus.sh \
#        <TICKET> '<question-or-decision-point>' [<context-file>]
#
# Output: Opus 4.7's verdict (<= ~700 tokens by prompt design), structured as
#   ANALYSIS: <2-4 sentences on what's at stake>
#   RECOMMENDATION: <concrete action(s) for the executor>
#   CAVEATS: <any qualifiers / what would change the answer>
#
# Cost control: each call burns one Opus 4.7 session, ~5K-15K input tokens
# depending on context-file size. Hard cap per ticket via QSHIP_ADVISOR_MAX_USES
# (default 3). Enforces by counting prior consult logs in the worktree.
#
# Override knobs:
#   QSHIP_ADVISOR_MODEL       advisor model (default opus[1m])
#   QSHIP_ADVISOR_MAX_USES    per-ticket cap (default 3)
#   QSHIP_ADVISOR_TIMEOUT_SEC wall-clock cap per call (default 600)
#   QSHIP_ADVISOR_DISABLED    set to "true" to no-op every call (debug/cost lock)

set -eo pipefail

TICKET="${1:-}"
QUESTION="${2:-}"
CONTEXT_FILE="${3:-}"

if [ -z "$TICKET" ] || [ -z "$QUESTION" ]; then
    echo "Usage: $0 <TICKET> '<question>' [<context-file>]" >&2
    exit 2
fi

# Hard kill switch (e.g. when quota is tight).
if [ "${QSHIP_ADVISOR_DISABLED:-false}" = "true" ]; then
    echo "ANALYSIS: Advisor disabled via QSHIP_ADVISOR_DISABLED — proceeding without consultation."
    echo "RECOMMENDATION: Continue with your best judgment."
    echo "CAVEATS: This response is a stub; no Opus reasoning was applied."
    exit 0
fi

WORKTREE_ROOT="${WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
TICKET_DIR="$WORKTREE_ROOT/$TICKET"
mkdir -p "$TICKET_DIR/advisor-logs"

# Enforce per-ticket cap — the primary cost lever per Anthropic's max_uses
# guidance. Exceeding it returns a stub so the executor doesn't loop.
MAX_USES="${QSHIP_ADVISOR_MAX_USES:-2}"
USED=$(find "$TICKET_DIR/advisor-logs" -type f -name 'consult-*.log' 2>/dev/null | wc -l | tr -d ' ')
if [ "$USED" -ge "$MAX_USES" ]; then
    echo "ANALYSIS: Advisor budget exhausted for $TICKET ($USED/$MAX_USES calls used)."
    echo "RECOMMENDATION: Use your existing analysis — the budget cap is intentional. Reserve future advisor calls for distinct decisions, not re-asking the same question."
    echo "CAVEATS: Override with QSHIP_ADVISOR_MAX_USES=<N> if a higher cap is genuinely warranted."
    exit 0
fi

# Build the consultation prompt. Anthropic's advisor pattern says:
# - keep the question concrete and decision-shaped
# - include only the context relevant to the decision (not the whole transcript)
# - ask for analysis + concrete recommendation + caveats
TS=$(date '+%Y%m%d-%H%M%S')
LOG="$TICKET_DIR/advisor-logs/consult-${TS}.log"
PROMPT_FILE="$TICKET_DIR/advisor-logs/consult-${TS}.prompt"

# Build the context block. Two modes:
#   1) executor passed an explicit context file → use that (curated mode)
#   2) executor passed nothing → auto-build a context bundle from worktree
#      state (smart-default mode)
#
# Auto-bundle pulls the artifacts an Opus advisor genuinely needs to reason
# about a /qship decision: the ticket spec, the AC scenarios, current diff
# state, latest test output, and the executor's progress notes. This mirrors
# what the native API advisor tool auto-forwards (full conversation), but
# scoped to the artifacts that actually inform decisions — full transcripts
# are mostly Sonnet's tool-call noise that doesn't help Opus.
#
# Cap each section so the prompt stays focused; total ~80K tokens (~320KB).
build_auto_context() {
    local td="$TICKET_DIR"
    local repo_root="${REPO_ROOT:-{{CODEBASE_ROOT}}}"
    {
        # 1. Ticket spec — fetched by qship-persist.sh as ticket.md if it exists.
        if [ -f "$td/ticket.md" ]; then
            echo "## Ticket spec ($TICKET)"
            head -c 8000 "$td/ticket.md"
            echo ""
        elif [ -f "$td/ticket.json" ]; then
            echo "## Ticket spec ($TICKET, JSON)"
            head -c 6000 "$td/ticket.json"
            echo ""
        fi

        # 2. Acceptance criteria + scenarios matrix — what the executor must satisfy.
        if [ -f "$td/required-scenarios.json" ]; then
            echo "## Required scenarios (Phase 3 evaluator contract)"
            head -c 8000 "$td/required-scenarios.json"
            echo ""
        fi

        # 3. Expected children + canaries (epic mode).
        if [ -s "$td/expected-children.txt" ]; then
            echo "## Expected child tickets (epic scope)"
            cat "$td/expected-children.txt"
            echo ""
        fi

        # 4. Phase 2 progress notes — executor's running state.
        if [ -f "$td/phase2-progress.md" ]; then
            echo "## Executor progress (phase2-progress.md)"
            head -c 12000 "$td/phase2-progress.md"
            echo ""
        fi

        # 5. Phase 3 evidence so far — what the executor has documented.
        if [ -f "$td/phase3-evidence.md" ]; then
            echo "## Phase 3 evidence (in progress)"
            head -c 10000 "$td/phase3-evidence.md"
            echo ""
        fi

        # 6. Current branch + recent commits + uncommitted diff stats. Find
        #    the worktree's git directory by looking up sibling repos.
        local branch_repo=""
        for r in $(jq -r ".[].name" "$SKILLS_ROOT/qship/repos.json"); do
            if [ -d "$repo_root/$r/.git" ]; then
                pushd "$repo_root/$r" >/dev/null 2>&1 || continue
                if git for-each-ref --format='%(refname:short)' "refs/heads/${TICKET}-*" 2>/dev/null | head -1 | grep -q .; then
                    branch_repo="$r"
                    break
                fi
                popd >/dev/null 2>&1 || true
            fi
        done
        if [ -n "$branch_repo" ]; then
            echo "## Git state in $branch_repo"
            git log --oneline -10 2>/dev/null || true
            echo "--- uncommitted changes (stat) ---"
            git diff --stat 2>/dev/null | head -30 || true
            echo "--- staged changes (stat) ---"
            git diff --cached --stat 2>/dev/null | head -30 || true
            popd >/dev/null 2>&1 || true
            echo ""
        fi

        # 7. Latest iter output snippet — last 200 lines of the most recent
        #    iter log gives Opus a window into what the executor most recently
        #    saw and decided.
        local latest_iter
        latest_iter=$(ls -t {{STATE_ROOT}}/persist-logs/${TICKET}-iter-*.log 2>/dev/null | head -1)
        if [ -n "$latest_iter" ] && [ -s "$latest_iter" ]; then
            echo "## Latest /qship iteration output (tail)"
            tail -c 16000 "$latest_iter"
            echo ""
        fi

        # 8. Latest test output — most recent pytest/lint failures the
        #    executor was working against. Heuristic: any *.log under the
        #    worktree mtime-sorted top-3.
        if [ -d "$td" ]; then
            echo "## Recent worktree logs (tail of top 3 by mtime)"
            for f in $(find "$td" -maxdepth 2 -type f \( -name '*.log' -o -name '*.txt' \) 2>/dev/null | xargs -I{} sh -c 'stat -f "%m %N" "$1" 2>/dev/null || stat -c "%Y %n" "$1" 2>/dev/null' _ {} | sort -rn | head -3 | awk '{print $2}'); do
                echo "### $f"
                tail -c 4000 "$f"
                echo ""
            done
        fi
    } | head -c 320000
}

# Snapshot strategy for cache hits (the "avoid double tokens" lever):
#
# Anthropic's prompt cache has a 5-min TTL and matches byte-identical prefixes
# across separate API requests under the same key. Cache reads cost 0.10x base
# vs cache writes at 1.25x. Break-even at ~3 calls per conversation per the
# docs. So we want the FIRST 80K tokens of every advisor call within the same
# ticket to be byte-identical → consult #2/#3 hit cache and pay 0.10x for the
# bundle prefix instead of full price.
#
# Strategy: snapshot the auto-bundle ONCE per ticket at first call, reuse the
# same snapshot for subsequent calls. The "what's new" between calls is
# appended as a small delta block AFTER the cacheable prefix, so cache hits
# the long stable part. Curated mode (explicit context file) skips this and
# uses the file directly — caller knows what they want.
SNAPSHOT="$TICKET_DIR/advisor-snapshot.md"
DELTA_BLOCK=""

CONTEXT_BLOCK=""
if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
    # Curated mode: executor packaged exactly what it wants Opus to see.
    CONTEXT_BLOCK=$(head -c 320000 "$CONTEXT_FILE")
else
    # Smart-default mode with cache-aware snapshot reuse:
    if [ ! -s "$SNAPSHOT" ]; then
        # First consult for this ticket — build + persist the snapshot.
        build_auto_context > "$SNAPSHOT"
    else
        # Subsequent consult — reuse snapshot for cacheable prefix, append a
        # small delta describing what's NEW since the snapshot was taken.
        # Delta is bounded to 8K so the cache prefix stays dominant.
        {
            echo ""
            echo "## DELTA since snapshot (changes between this consult and the previous one)"
            local snapshot_age_sec
            if stat -f '%m' "$SNAPSHOT" >/dev/null 2>&1 || stat -c '%Y' "$SNAPSHOT" >/dev/null 2>&1; then
                snapshot_age_sec=$(( $(date +%s) - $(stat -f '%m' "$SNAPSHOT" 2>/dev/null || stat -c '%Y' "$SNAPSHOT") ))
                echo "Snapshot age: ${snapshot_age_sec}s"
            fi
            local repo_root="${REPO_ROOT:-{{CODEBASE_ROOT}}}"
            local branch_repo=""
            for r in $(jq -r ".[].name" "$SKILLS_ROOT/qship/repos.json"); do
                if [ -d "$repo_root/$r/.git" ]; then
                    pushd "$repo_root/$r" >/dev/null 2>&1 || continue
                    if git for-each-ref --format='%(refname:short)' "refs/heads/${TICKET}-*" 2>/dev/null | head -1 | grep -q .; then
                        branch_repo="$r"
                        break
                    fi
                    popd >/dev/null 2>&1 || true
                fi
            done
            if [ -n "$branch_repo" ]; then
                echo "### New commits since snapshot ($branch_repo):"
                local snap_ts
                snap_ts=$(stat -f '%m' "$SNAPSHOT" 2>/dev/null || stat -c '%Y' "$SNAPSHOT" 2>/dev/null || echo 0)
                local snap_iso
                snap_iso=$(date -r "$snap_ts" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$snap_ts" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "1970-01-01T00:00:00")
                git log --oneline --since="$snap_iso" 2>/dev/null | head -10 || true
                echo "### Current uncommitted diff stat:"
                git diff --stat 2>/dev/null | head -10 || true
                popd >/dev/null 2>&1 || true
            fi
            local latest_iter
            latest_iter=$(ls -t {{STATE_ROOT}}/persist-logs/${TICKET}-iter-*.log 2>/dev/null | head -1)
            if [ -n "$latest_iter" ] && [ -s "$latest_iter" ]; then
                echo "### Tail of latest iter log (might be a new iter since snapshot):"
                tail -c 4000 "$latest_iter"
            fi
        } > "$TICKET_DIR/advisor-logs/delta-${TS}.md"
        DELTA_BLOCK=$(head -c 8192 "$TICKET_DIR/advisor-logs/delta-${TS}.md")
    fi
    # Final context = stable snapshot (cacheable) + small delta (varies).
    # The DELTA goes AFTER the snapshot so the cache-friendly prefix stays
    # byte-identical across calls.
    CONTEXT_BLOCK=$(head -c 320000 "$SNAPSHOT")
    if [ -n "$DELTA_BLOCK" ]; then
        CONTEXT_BLOCK="$CONTEXT_BLOCK"$'\n'"$DELTA_BLOCK"
    fi
fi

{
    echo "You are an expert software-engineering advisor consulting on a single decision point inside an autonomous coding agent (running /qship on Jira ticket $TICKET). Your role is strictly advisory — you do NOT execute, write code, or call tools. The executor (Sonnet 4.6) will read your verdict and act on it."
    echo ""
    echo "OUTPUT FORMAT (mandatory, exactly 3 sections, ~700 tokens total):"
    echo "  ANALYSIS: <2-4 sentences on what's actually at stake — what would go wrong if the executor picks the wrong path>"
    echo "  RECOMMENDATION: <one concrete recommended action OR a small ranked list — be specific about files, function signatures, edge cases>"
    echo "  CAVEATS: <conditions under which the recommendation changes; what the executor should re-check before committing to it>"
    echo ""
    echo "Be direct. Do not pad. Do not restate the question. Do not propose multiple alternatives unless the choice between them depends on a fact the executor can verify quickly."
    echo ""
    echo "DECISION POINT (from the executor):"
    echo "$QUESTION"
    if [ -n "$CONTEXT_BLOCK" ]; then
        echo ""
        echo "CONTEXT (gathered by the executor before consulting):"
        echo "---"
        echo "$CONTEXT_BLOCK"
        echo "---"
    fi
} > "$PROMPT_FILE"

# Wall-clock cap. Advisor calls are bounded reasoning, not tool-using agents,
# so 10 min is generous.
TIMEOUT_SEC="${QSHIP_ADVISOR_TIMEOUT_SEC:-600}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

ADVISOR_MODEL="${QSHIP_ADVISOR_MODEL:-opus[1m]}"

# Headless one-shot. No tools — advisor is reasoning-only by Anthropic's
# design. --append-system-prompt deliberately empty to maximize cache hits
# across consultations (the prompt body lives in the user message).
run_advisor() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" --kill-after=15s "$TIMEOUT_SEC" \
            claude --print --dangerously-skip-permissions \
                --model "$ADVISOR_MODEL" \
                --effort "${QSHIP_ADVISOR_EFFORT:-xhigh}" \
                "$(cat "$PROMPT_FILE")"
    else
        claude --print --dangerously-skip-permissions \
            --model "$ADVISOR_MODEL" \
            --effort "${QSHIP_ADVISOR_EFFORT:-xhigh}" \
            "$(cat "$PROMPT_FILE")"
    fi
}

VERDICT=$(run_advisor 2>&1) || true

# Persist for audit + future learning extraction. Each consult is a candidate
# entry for AGENTS.md if the recommendation actually unblocked the executor.
{
    echo "=== consult $TS — ticket $TICKET ($((USED + 1))/$MAX_USES) ==="
    echo "Model: $ADVISOR_MODEL"
    echo "Question: $QUESTION"
    echo "--- verdict ---"
    echo "$VERDICT"
} > "$LOG"

echo "$VERDICT"
