#!/bin/bash
# Stop / SubagentStop hook: block termination while a qship pipeline has
# PENDING work OR insufficient E2E evidence for the change it made.
#
# Wire into ~/.claude/settings.json under BOTH hooks.Stop and hooks.SubagentStop
# with matcher "". The harness sends JSON on stdin including `stop_hook_active`,
# which we honour to prevent infinite loops.
#
# Decision contract:
#   allow stop → {"continue": true}                          (exit 0)
#   block stop → {"decision": "block", "reason": "<why>"}    (exit 0)
#
# Per-ticket checks inside {{STATE_ROOT}}/worktrees/<TICKET>/:
#   1. phase2-progress.md      — any `| PENDING |` row → block
#   2. trd-coverage.json       — any `passes == false` → block
#   3. phase3-evidence.md      — evaluated against pipeline-context.json:
#        - api_changed=true         → requires API HTTP evidence OR api rationale
#        - ui_changed=true OR
#          ui_consumer_changed=true → requires Playwright results.json w/
#                                     stats.unexpected==0 AND a trace.zip path,
#                                     OR a rationale escape
#      Missing pipeline-context.json → falls back to legacy "any HTTP evidence
#      or 'no network surface'" check to avoid false-positive blocks on
#      pipelines that predate this schema.
#
# Stale worktrees (>QSHIP_FRESHNESS_MIN, default 240 min) are treated as
# abandoned and DO NOT block — `rm -rf {{STATE_ROOT}}/worktrees/<TICKET>` to clear.
#
# Escape hatches:
#   QSHIP_SKIP_UI_E2E=<reason>  → line in phase3-evidence.md satisfies UI check
#   "no api surface: <reason>"  → line in API Evidence section satisfies API check
#   "no ui surface: <reason>"   → line in UI Evidence section satisfies UI check
#   All rationales must cite at least one file path (> 1 char after the colon).

set -eo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./qship-evidence-lib.sh
source "$HOOK_DIR/qship-evidence-lib.sh"

WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
FRESHNESS_MIN="${QSHIP_FRESHNESS_MIN:-240}"
EPIC_ROOT="${QSHIP_EPIC_ROOT:-/tmp}"   # epic state dirs live at {{STATE_ROOT}}/epic-<EPIC>/

# Returns 0 if the given ticket is listed in an epic's state.json as a member
# of a wave that has NOT yet been merged into the consolidated epic branch.
# When this is the case we DEFER the per-ticket phase3 gate — the wave-level
# gate ({{STATE_ROOT}}/epic-<EPIC>/wave-<N>-phase3-evidence.md) is the real bar.
#
# Epic state.json schema (written in Step E0):
#   {"epic_id":"{{JIRA_PROJECT_KEY}}-EX01","tickets":["{{JIRA_PROJECT_KEY}}-EX01b","{{JIRA_PROJECT_KEY}}-554",...],
#    "waves":[{"n":1,"tickets":[...],"merged":true},
#             {"n":2,"tickets":[...],"merged":false}]}
ticket_is_in_unmerged_epic_wave() {
  local ticket="$1"
  local state
  for state in "$EPIC_ROOT"/qship-epic-*/state.json; do
    [ -e "$state" ] || continue
    # Match: ticket appears in a wave whose merged flag is false.
    if jq -e --arg t "$ticket" '
        .waves[]?
        | select((.merged // false) == false)
        | .tickets[]?
        | select(. == $t)
      ' "$state" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

input=$(cat 2>/dev/null || echo '{}')
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")

emit_continue() { echo '{"continue": true}'; exit 0; }
emit_block() { jq -Rn --arg r "$1" '{decision: "block", reason: $r}'; exit 0; }

# CRITICAL: never re-enter — harness-level infinite-loop guard.
if [ "$stop_hook_active" = "true" ]; then
  emit_continue
fi

if [ ! -d "$WORKTREE_ROOT" ]; then
  emit_continue
fi

# --- session-scope guard ----------------------------------------------------
# This hook is registered globally in ~/.claude/settings.json, so it fires on
# EVERY Stop / SubagentStop event in EVERY Claude Code session — including
# sessions in unrelated repos that have nothing to do with qship. Without this
# guard the hook keeps surfacing stale `{{STATE_ROOT}}/worktrees/<TICKET>` from a
# different session as a "blocker" in the unrelated session, which pressures
# the agent to `rm -rf` someone else's in-progress work just to clear the
# block. That's destructive convenience masquerading as cleanup.
#
# This session counts as a qship session iff at least one signal matches:
#   1. QSHIP_SESSION=1 in the spawned process env (set by qship-persist.sh).
#   2. cwd is under {{STATE_ROOT}}/worktrees/ or {{STATE_ROOT}}/epic-*.
#   3. The session transcript records an actual qship slash-command invocation
#      via Claude Code's <command-name>/qship...</command-name> marker, AND
#      that marker sits inside a user-role JSONL record (i.e. the user really
#      typed the slash command). We anchor on `"role":"user","content":"…
#      <command-name>/qship…` to avoid two prior bugs:
#        a. Free-text mentions of "/qship" or "qship-…" paths matched (the
#           hook's own error message and skill listings contain those strings,
#           which caused the marker to self-perpetuate across sessions).
#        b. Bash output that happened to contain the literal <command-name>
#           tag — e.g. while debugging this hook — also matched.
#      A real slash command is the only thing that produces the user-role
#      record + tag combination on a single JSONL line.
# If none match, emit_continue and stay out of the unrelated session's way.
session_is_qship() {
  if [ "${QSHIP_SESSION:-0}" = "1" ]; then
    return 0
  fi
  local cwd transcript
  cwd=$(echo "$input" | jq -r '.cwd // ""' 2>/dev/null)
  transcript=$(echo "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
  case "$cwd" in
    {{STATE_ROOT}}/worktrees/*|{{STATE_ROOT}}/epic-*) return 0 ;;
  esac
  if [ -n "$transcript" ] && [ -f "$transcript" ] \
     && grep -qE '"role":"user","content":"[^"]*<command-name>/qship[a-z0-9]*</command-name>' "$transcript" 2>/dev/null; then
    return 0
  fi
  return 1
}

if ! session_is_qship; then
  emit_continue
fi

# --- main loop over fresh progress files -------------------------------------
# validate_phase3_evidence and phase3_has_missing_e2e come from
# qship-evidence-lib.sh (sourced at top).

fresh_list=$(find "$WORKTREE_ROOT" -maxdepth 2 -type f \
  \( -name 'phase2-progress.md' -o -name 'phase3-evidence.md' -o -name 'trd-coverage.json' \) \
  -mmin "-${FRESHNESS_MIN}" 2>/dev/null || true)

if [ -z "$fresh_list" ]; then
  emit_continue
fi

# Build per-ticket fresh-flag set and collect blockers.
blockers=()
seen_tickets=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  ticket_dir=$(dirname "$file")
  ticket_id=$(basename "$ticket_dir")
  base=$(basename "$file")

  # EPIC_MODE deferral: if this ticket is in any epic wave, per-ticket Phase 2
  # and Phase 3 checks don't apply — the orchestrator runs them once per wave
  # against the merged epic branch (wave-<N>-phase23-evidence.md). Previously
  # only phase3-evidence.md was skipped here, which left phase2-progress.md
  # firing forever on tickets whose workers correctly stopped at Phase 1 (see
  # {{JIRA_PROJECT_KEY}}-EX04 stall — block fired ~200 times across the run).
  if ticket_is_in_unmerged_epic_wave "$ticket_id"; then
    if [ "$base" = "phase3-evidence.md" ] || [ "$base" = "phase2-progress.md" ]; then
      continue
    fi
  fi

  case "$base" in
    phase2-progress.md)
      if grep -q '| PENDING |' "$file" 2>/dev/null; then
        pending_rows=$(grep '| PENDING |' "$file" | sed 's/^| *//' | cut -d'|' -f1 | sed 's/ *$//' | paste -sd ', ' -)
        blockers+=("${ticket_id}: Phase 2 steps still PENDING → ${pending_rows}")
      fi
      ;;
    phase3-evidence.md)
      err=$(validate_phase3_evidence "$ticket_id" "$ticket_dir" 2>&1 1>/dev/null || true)
      if [ -n "$err" ]; then
        blockers+=("$err")
      fi
      ;;
    trd-coverage.json)
      if jq -e '[.[] | select(.passes == false)] | length > 0' "$file" >/dev/null 2>&1; then
        unmet=$(jq -r '[.[] | select(.passes == false) | .id] | join(", ")' "$file" 2>/dev/null || echo "?")
        blockers+=("${ticket_id}: TRD acceptance criteria not yet passing → ${unmet}")
      fi
      ;;
  esac

  # Track ticket so we can also detect "phase2 done but no phase3-evidence at all".
  case ",${seen_tickets}," in
    *",${ticket_id},"*) ;;
    *) seen_tickets="${seen_tickets},${ticket_id}" ;;
  esac
done <<< "$fresh_list"

# Additional check: phase3-evidence.md missing when pipeline-context says E2E
# was required. Delegates to the shared lib so the rule stays in one place.
IFS=',' read -r -a ticket_arr <<< "$seen_tickets"
for t in "${ticket_arr[@]}"; do
  [ -z "$t" ] && continue
  # EPIC_MODE deferral — see ticket_is_in_unmerged_epic_wave().
  if ticket_is_in_unmerged_epic_wave "$t"; then
    continue
  fi
  tdir="$WORKTREE_ROOT/$t"
  p2="$tdir/phase2-progress.md"
  # Only check if Phase 2 is fully done — avoids duplicate blockers while work is in flight.
  if [ -f "$p2" ] && ! grep -q '| PENDING |' "$p2" 2>/dev/null; then
    err=$(phase3_has_missing_e2e "$t" "$tdir" 2>&1 >/dev/null || true)
    [ -n "$err" ] && blockers+=("$err")
  fi
done

# Wave-level Phase 3 gate (EPIC_MODE only).
# When ALL tickets in a wave are merged into the consolidated epic branch, the
# orchestrator must produce wave-<N>-phase3-evidence.md before any Phase 4
# action. We only block when the wave is fully merged (merged=true) AND its
# evidence file is missing/empty — otherwise we'd block the orchestrator while
# it is mid-wave.
for state in "$EPIC_ROOT"/qship-epic-*/state.json; do
  [ -e "$state" ] || continue
  epic_dir=$(dirname "$state")
  while IFS= read -r wave_n; do
    [ -z "$wave_n" ] && continue
    # qshipmaster writes wave-<N>-phase23-evidence.md (combined Phase 2+3).
    # Earlier versions of this hook looked for wave-<N>-phase3-evidence.md
    # and silently never blocked. Accept either filename.
    wave_evidence=""
    for cand in "$epic_dir/wave-${wave_n}-phase23-evidence.md" "$epic_dir/wave-${wave_n}-phase3-evidence.md"; do
      [ -s "$cand" ] && { wave_evidence="$cand"; break; }
    done
    epic_id=$(jq -r '.epic // .epic_id // ""' "$state" 2>/dev/null)
    if [ -z "$wave_evidence" ]; then
      blockers+=("${epic_id} Wave ${wave_n}: merged into consolidated epic branch but missing wave-${wave_n}-phase23-evidence.md. Run wave-level Phase 2/3 review against the wave diff.")
      continue
    fi
    # Phase 2 content check — qsimplify/qcheck/qbug/qbcheck must have left
    # markers. The dispatch prompt is required to emit a checklist with
    # these literal headings; if any are missing the wave Phase 2 batch
    # silently no-op'd ({{JIRA_PROJECT_KEY}}-EX14 incident).
    for marker in 'qsimplify' 'qcheck' 'qbug' 'qbcheck'; do
      if ! grep -qi "$marker" "$wave_evidence" 2>/dev/null; then
        blockers+=("${epic_id} Wave ${wave_n}: $wave_evidence has no '$marker' marker — Phase 2 review subagent did not run.")
      fi
    done
    # Phase 3 content check — at least one of phase 3 / e2e / scenario.
    if ! grep -qiE 'phase 3|e2e|scenario|playwright' "$wave_evidence" 2>/dev/null; then
      blockers+=("${epic_id} Wave ${wave_n}: $wave_evidence has no Phase 3 / E2E / scenario content.")
    fi
    # qshipmaster sets .waves[].status="shipped"; older code expected merged=true.
  done < <(jq -r '.waves[]? | select((.status // "") == "shipped" or (.merged // false) == true) | .n' "$state" 2>/dev/null)
done

if [ "${#blockers[@]}" -eq 0 ]; then
  emit_continue
fi

reason="qship pipeline is not complete. Resume work on the following before stopping:"$'\n'
for b in "${blockers[@]}"; do
  reason+="  - ${b}"$'\n'
done
reason+=$'\n'"To resume:"$'\n'
reason+="  - Missing pipeline-context.json? Run: bash ~/.claude/skills/qship/hooks/qship-compute-context.sh <TICKET>"$'\n'
reason+="  - UI evidence required? Run /qe2etest (which delegates UI to qmanualt + Playwright); produce test-results/playwright-results.json and trace.zip."$'\n'
reason+="  - No UI surface? Add 'no ui surface: <file-cited reason>' line to the ## UI Evidence section."$'\n'
reason+=$'\n'"DO NOT delete a worktree to clear this block unless YOU created it and the work is genuinely abandoned."$'\n'
reason+="The blocked ticket may belong to another session/agent that is still working. If it isn't yours, the right action is to leave it alone and end your turn — the hook only blocks qship sessions (cwd under {{STATE_ROOT}}/worktrees/, QSHIP_SESSION=1, or transcript references qship); if you reached this block in an unrelated session that's a hook-scoping bug, report it instead of deleting state."$'\n'
reason+="If the pipeline really is yours and abandoned: rm -rf ${WORKTREE_ROOT}/<TICKET> clears it."

emit_block "$reason"
