#!/bin/bash
# qshipmaster-learn.sh — append a wave-level Phase 2 fix learning to
# ~/.claude/skills/qshipmaster/AGENTS.md so future epic runs see what's
# previously bitten us. Pattern from ralph-zero (procedural memory across
# sessions).
#
# Usage:
#   qshipmaster-learn.sh <EPIC> <wave_n> <repo> <fix_iter>
#
# Reads the wave's phase2 evidence log + the dispatched fix-worker log,
# extracts a 1-3 line root cause + fix summary via a haiku call, and
# appends a dated entry to AGENTS.md. Idempotent: each (epic, wave, repo,
# fix_iter) writes exactly one entry.

set -eo pipefail

EPIC="${1:-}"
WAVE_N="${2:-}"
REPO="${3:-}"
FIX_ITER="${4:-1}"
if [ -z "$EPIC" ] || [ -z "$WAVE_N" ] || [ -z "$REPO" ]; then
    echo "Usage: $0 <EPIC> <wave_n> <repo> [fix_iter]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_FILE="$(dirname "$SCRIPT_DIR")/AGENTS.md"
EPIC_DIR="${EPIC_ROOT:-{{STATE_ROOT}}-epic}-${EPIC}"

PHASE2_LOG="$EPIC_DIR/wave-${WAVE_N}-${REPO}-phase2.log"
FIX_LOG="$EPIC_DIR/logs/wave-${WAVE_N}-${REPO}-fix-iter-${FIX_ITER}.log"
if [ ! -s "$PHASE2_LOG" ] || [ ! -s "$FIX_LOG" ]; then
    echo "[learn] no phase2/fix logs to learn from at $PHASE2_LOG / $FIX_LOG" >&2
    exit 0
fi

ENTRY_KEY="${EPIC}-wave${WAVE_N}-${REPO}-iter${FIX_ITER}"
if [ -f "$AGENTS_FILE" ] && grep -qF "<!-- key: $ENTRY_KEY -->" "$AGENTS_FILE"; then
    echo "[learn] entry $ENTRY_KEY already in AGENTS.md — skipping"
    exit 0
fi

# One haiku call to summarise root cause + fix in 1-3 lines.
SUMMARY=$(claude --print --dangerously-skip-permissions \
    --allowedTools 'Read' \
    --model haiku \
    "Read these two logs from a wave-level Phase 2 review failure on epic $EPIC, wave $WAVE_N, repo $REPO. The first is the failing lint/test output. The second is what the fix worker did. Output EXACTLY 3 lines, no prose, no markdown:
LINE 1: ROOT_CAUSE: <under-15-words explanation of what actually broke>
LINE 2: FIX: <under-15-words explanation of what the worker changed>
LINE 3: RULE: <under-20-words actionable rule to prevent recurrence in future epics>

Phase 2 log: $PHASE2_LOG
Fix log: $FIX_LOG" 2>/dev/null | head -3 || echo "")

if [ -z "$SUMMARY" ]; then
    echo "[learn] haiku produced empty summary — skipping"
    exit 0
fi

# Schema gate. Reject anything that isn't ROOT_CAUSE/FIX/RULE structured —
# without this, free-prose haiku output (or transcript-leak from a wedged
# fix-worker log) gets appended verbatim and poisons every future worker's
# system prompt via the AGENTS.md memory-block injection.
if ! printf '%s\n' "$SUMMARY" | grep -qE '^[[:space:]]*ROOT_CAUSE:'; then
    echo "[learn] summary missing ROOT_CAUSE: prefix — refusing to append (schema violation)" >&2
    echo "[learn] raw output was:" >&2
    printf '%s\n' "$SUMMARY" | head -10 >&2
    exit 0
fi
if ! printf '%s\n' "$SUMMARY" | grep -qE '^[[:space:]]*FIX:'; then
    echo "[learn] summary missing FIX: prefix — refusing to append" >&2
    exit 0
fi
if ! printf '%s\n' "$SUMMARY" | grep -qE '^[[:space:]]*RULE:'; then
    echo "[learn] summary missing RULE: prefix — refusing to append" >&2
    exit 0
fi
# Hard length cap: a 3-line entry should never exceed ~600 chars; anything
# bigger means the haiku ran away or transcript text leaked in.
if [ "${#SUMMARY}" -gt 600 ]; then
    echo "[learn] summary length ${#SUMMARY} > 600 chars — refusing to append (likely transcript leak)" >&2
    exit 0
fi

# Initialize AGENTS.md if it doesn't exist.
if [ ! -f "$AGENTS_FILE" ]; then
    cat > "$AGENTS_FILE" <<'HDR'
# qshipmaster — Cross-Epic Learnings (AGENTS.md)

This file is procedural memory across qshipmaster runs. Each entry records a
wave-level Phase 2 failure that required a fix-worker iteration, so future
epic orchestration can avoid repeating the same root causes.

Pattern source: ralph-zero (https://github.com/davidkimai/ralph-zero) —
mandatory `AGENTS.md` documentation injected into each fresh agent session.

`qship-persist.sh` reads this file and folds the most recent ~15 entries into
its autonomy directive, so workers see prior pitfalls before running.

---
HDR
fi

# Append the dated entry with a key marker for idempotence.
{
    echo ""
    echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) — $EPIC wave $WAVE_N ($REPO)"
    echo "<!-- key: $ENTRY_KEY -->"
    echo ""
    echo "$SUMMARY" | sed 's/^/- /'
} >> "$AGENTS_FILE"

echo "[learn] appended entry $ENTRY_KEY to $AGENTS_FILE"
