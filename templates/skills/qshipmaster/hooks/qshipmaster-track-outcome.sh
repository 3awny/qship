#!/usr/bin/env bash
# qshipmaster-track-outcome.sh — gap #3 (per-version outcome telemetry).
#
# Called by the supervisor at the END of each epic to record whether each
# previously-applied self-improve patch's failure class RECURRED in the
# just-finished epic. After REGRESSION_STREAK_REVERT (default 3) consecutive
# epics where a patch's class re-fires, the patch is auto-reverted via git
# and the user gets an inbox alert.
#
# Usage: qshipmaster-track-outcome.sh <EPIC>
#
# Reads {{STATE_ROOT}}/epic-<EPIC>/state.json + qshipmaster.log to extract which
# failure classes fired during the epic, cross-references with patches in
# .patch-history.json that targeted those classes, and updates each patch's
# outcomes.epics_observed[] with PASS (class didn't fire) or FAIL (class
# fired again — patch ineffective).
#
# Exit codes:
#   0  = telemetry updated
#   1  = nothing to track (no patches or no state.json)
#   2  = auto-revert triggered for at least one patch

set -eo pipefail

EPIC="${1:-}"
[ -z "$EPIC" ] && { echo "usage: $0 <EPIC>" >&2; exit 2; }

SKILL_ROOT="$HOME/.claude/skills/qshipmaster"
PATCH_HISTORY="$SKILL_ROOT/.patch-history.json"
AUDIT_LOG="$SKILL_ROOT/self-improve.log"
EPIC_DIR="{{STATE_ROOT}}/epic-$EPIC"
INBOX_DIR="$EPIC_DIR/inbox"
REGRESSION_STREAK_REVERT="${QSHIPMASTER_REGRESSION_STREAK:-3}"

mkdir -p "$INBOX_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [outcome-tracking/$EPIC] $1" | tee -a "$AUDIT_LOG"; }

[ ! -f "$PATCH_HISTORY" ] && { log "no patch history — nothing to track"; exit 1; }
[ ! -f "$EPIC_DIR/qshipmaster.log" ] && { log "no qshipmaster.log for $EPIC — cannot extract observed failures"; exit 1; }

# Extract failure classes observed in this epic (supervisor logs them).
# Format: lines containing "HEAL applied" or "ESCALATED" + a class-key marker.
observed_classes_file="$EPIC_DIR/observed-failure-classes.txt"
grep -oE "FAILURE_CLASS=[a-z_][a-z0-9_]+" "$EPIC_DIR/qshipmaster.log" 2>/dev/null \
  | sed 's/^FAILURE_CLASS=//' | sort -u > "$observed_classes_file" || true

patch_count=$(jq '.patches | length' "$PATCH_HISTORY")
[ "$patch_count" = "0" ] && { log "no patches in history — nothing to track"; exit 1; }

reverted_any=0

# For each patch in history, did its failure class recur in this epic?
# Read patch list and iterate (jq + bash)
jq -c '.patches | to_entries[] | select(.value.reverted // false | not)' "$PATCH_HISTORY" | while read -r entry; do
  idx=$(echo "$entry" | jq -r '.key')
  patch=$(echo "$entry" | jq -r '.value')
  key=$(echo "$patch" | jq -r '.key')
  target=$(echo "$patch" | jq -r '.target_file')
  applied_at=$(echo "$patch" | jq -r '.applied_at')
  applied_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$applied_at" "+%s" 2>/dev/null || echo 0)
  # Only track patches applied at least 1 epic ago (skip the one we just made)
  now_epoch=$(date "+%s")
  [ $((now_epoch - applied_epoch)) -lt 60 ] && continue

  if grep -q "^$key$" "$observed_classes_file"; then
    outcome="FAIL"
    log "patch '$key' (target: $target): class RECURRED in epic $EPIC — outcome FAIL"
  else
    outcome="PASS"
    log "patch '$key' (target: $target): class did NOT recur in epic $EPIC — outcome PASS"
  fi

  # Append outcome to .epics_observed[]
  jq --argjson idx "$idx" --arg epic "$EPIC" --arg outcome "$outcome" \
     '.patches[$idx].outcomes.epics_observed += [{epic: $epic, outcome: $outcome}]' \
     "$PATCH_HISTORY" > "$PATCH_HISTORY.new" && mv "$PATCH_HISTORY.new" "$PATCH_HISTORY"

  # Check regression streak: last N observations all FAIL?
  recent_outcomes=$(jq -r ".patches[$idx].outcomes.epics_observed[-${REGRESSION_STREAK_REVERT}:][].outcome" "$PATCH_HISTORY")
  fail_streak=$(echo "$recent_outcomes" | grep -c "^FAIL$" || true)
  total=$(echo "$recent_outcomes" | wc -l | tr -d ' ')
  if [ "$fail_streak" = "$REGRESSION_STREAK_REVERT" ] && [ "$total" -ge "$REGRESSION_STREAK_REVERT" ]; then
    sha=$(echo "$patch" | jq -r '.git_sha')
    backup=$(echo "$patch" | jq -r '.backup_path')
    log "⚠ gap #3: patch '$key' failed $REGRESSION_STREAK_REVERT epics in a row — AUTO-REVERTING"

    # Try git revert first (gap #2)
    if [ "$sha" != "null" ] && [ -n "$sha" ] && git -C "$SKILL_ROOT" cat-file -e "$sha" 2>/dev/null; then
      git -C "$SKILL_ROOT" revert --no-edit "$sha" -q 2>&1 | tee -a "$AUDIT_LOG" || true
    fi

    # Belt + suspenders: also restore from filesystem backup if it exists and
    # target was outside SKILL_ROOT git repo
    if [ -f "$backup" ] && [[ "$target" != "$SKILL_ROOT"* ]]; then
      cp "$backup" "$target"
      log "filesystem-restored $target from $backup"
    fi

    # Mark in history
    jq --argjson idx "$idx" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.patches[$idx].reverted = true | .patches[$idx].reverted_at = $ts | .patches[$idx].revert_reason = "regression_streak"' \
       "$PATCH_HISTORY" > "$PATCH_HISTORY.new" && mv "$PATCH_HISTORY.new" "$PATCH_HISTORY"

    # Audit-only note (no user escalation — fully autonomous mode). The
    # supervisor will re-attempt this failure class in the next epic with a
    # DIFFERENT research strategy: alternative search query, higher source-
    # diversity requirement, or a fall-back fix pattern. Record the reverted
    # patch in the deferred ledger so the self-improve research stage knows
    # the previous approach didn't work.
    {
      echo "# Self-improve auto-revert (audit-only, no human action needed): $key"
      echo ""
      echo "Patch applied at: $applied_at"
      echo "Target file: $target"
      echo "Git sha (reverted): $sha"
      echo "Reason: failure class recurred in $REGRESSION_STREAK_REVERT consecutive epics — patch was not effective."
      echo ""
      echo "Recent outcomes:"
      jq -r ".patches[$idx].outcomes.epics_observed[].outcome" "$PATCH_HISTORY" | sed 's/^/  - /'
      echo ""
      echo "Next epic: self-improve will retry with an alternative research strategy. No human action required."
    } > "$INBOX_DIR/auto-revert-$key-$(date '+%Y%m%d-%H%M%S').md"

    # Record in deferred ledger so next-epic self-improve research stage
    # knows to try a different angle (different query terms, different fix
    # pattern). The supervisor reads this list when formulating its next
    # WebSearch query.
    jq --arg key "$key" --arg epic "$EPIC" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg target "$target" --arg sha "$sha" \
       '.deferred = (.deferred // []) + [{
          key: $key,
          epic: $epic,
          deferred_at: $ts,
          reason: "regression_streak_revert",
          target_file: $target,
          reverted_sha: $sha,
          retry_strategy: "alternative_research_required"
        }]' \
       "$PATCH_HISTORY" > "$PATCH_HISTORY.new" && mv "$PATCH_HISTORY.new" "$PATCH_HISTORY"
    reverted_any=1
  fi
done

if [ "$reverted_any" = "1" ]; then
  log "outcome tracking complete: 1+ patches auto-reverted. See $INBOX_DIR/ for alerts."
  exit 2
fi

log "outcome tracking complete: all active patches still effective"
exit 0
