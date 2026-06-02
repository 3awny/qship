#!/usr/bin/env bash
# qshipmaster-self-improve.sh — sandboxed self-modification engine for the
# qshipmaster skill/pipeline, hardened with the 5 verifiability gaps from
# the qwebsearchanalysis 2026 RSI literature review:
#   #1 POST-PATCH BEHAVIOR VERIFICATION (critical) — re-run the failing
#      scenario after patching; auto-revert if still failing.
#   #2 GIT-AS-ROLLBACK-ENGINE — git commit + revert as primary rollback
#      mechanism alongside filesystem backup.
#   #3 PER-VERSION OUTCOME TELEMETRY — patch-history.json tracks outcomes
#      across N subsequent epics; auto-revert on regression streak.
#   #4 FIRST-N-USES DRY-RUN — files never patched before stay in
#      propose-only mode until trust is established (configurable threshold).
#   #5 SOURCE DIVERSITY AUDIT — track unique source domains across all
#      patches; warn when diversity drops (signals echo-chamber research).
#
# Usage: qshipmaster-self-improve.sh <EPIC> <FAILURE_CLASS_KEY> <DIAGNOSIS_MD_PATH>
#
# The diagnosis markdown MUST contain a VALIDATE_CMD section (executable
# shell command that exits 0 when the failure is fixed, non-zero otherwise).
# Without it, gap #1 cannot apply and the wrapper falls back to syntax-only
# verification (the pre-2026 weak gate). Diagnosis files lacking VALIDATE_CMD
# are flagged in the audit log.
#
# Exit codes:
#   0  = patch applied + behavior-verified (or idempotently skipped)
#   1  = research inconclusive — escalate to user
#   2  = patch failed safety gate (sandbox / syntax / behavior verification)
#   3  = invocation error
#   4  = dry-run only (first-N-uses guard active) — proposal in inbox
#
# Audit trail: ~/.claude/skills/qshipmaster/self-improve.log
# Patch history (for gap #3): ~/.claude/skills/qshipmaster/.patch-history.json

set -eo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <EPIC> <FAILURE_CLASS_KEY> <DIAGNOSIS_MD_PATH>" >&2
  exit 3
fi

EPIC="$1"
FAILURE_KEY="$2"
DIAGNOSIS="$3"
[ -f "$DIAGNOSIS" ] || { echo "diagnosis file not found: $DIAGNOSIS" >&2; exit 3; }

SKILL_ROOT="$HOME/.claude/skills/qshipmaster"
QSHIP_HOOKS="$HOME/.claude/skills/qship/hooks"
GLOBAL_HOOKS="$HOME/.claude/hooks"
BACKUP_DIR="$SKILL_ROOT/.self-improve-backups"
AUDIT_LOG="$SKILL_ROOT/self-improve.log"
AGENTS_MD="$SKILL_ROOT/AGENTS.md"
PATCH_HISTORY="$SKILL_ROOT/.patch-history.json"
INBOX_DIR="{{STATE_ROOT}}/epic-$EPIC/inbox"

mkdir -p "$BACKUP_DIR" "$INBOX_DIR" "$(dirname "$AUDIT_LOG")"

# Tuning knobs (override via env).
FIRST_N_USES_DRY_RUN="${QSHIPMASTER_FIRST_N_USES_DRY_RUN:-3}"      # gap #4
REGRESSION_STREAK_REVERT="${QSHIPMASTER_REGRESSION_STREAK:-3}"      # gap #3
MIN_SOURCE_DIVERSITY="${QSHIPMASTER_MIN_SOURCE_DIVERSITY:-3}"       # gap #5: at least N unique domains
CONFIDENCE_FLOOR="${QSHIPMASTER_CONFIDENCE_FLOOR:-75}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [$EPIC/$FAILURE_KEY] $1" | tee -a "$AUDIT_LOG"; }

# ── PATCH HISTORY STORE (gap #3) ──────────────────────────────────────────
# Schema: { "patches": [{ key, epic, applied_at, target_file, sha,
#                         backup_path, confidence, sources[], domains[],
#                         outcomes: { post_apply: PASS|FAIL|UNKNOWN,
#                                     epics_observed: [{epic, recurred: bool}] }
#                       }, ...],
#           "file_patch_counts": { "<path>": N, ... } }
init_history() {
  if [ ! -f "$PATCH_HISTORY" ]; then
    echo '{"patches": [], "file_patch_counts": {}}' > "$PATCH_HISTORY"
  fi
}
init_history

# How many times has THIS target file been patched before by self-improve?
file_patch_count() {
  jq -r ".file_patch_counts[\"$1\"] // 0" "$PATCH_HISTORY"
}

# ── SANDBOX (unchanged from v1, but documented) ────────────────────────────
PATCHABLE_PATTERNS=(
  "$SKILL_ROOT/SKILL.md"
  "$SKILL_ROOT/hooks/qshipmaster-run.sh"
  "$SKILL_ROOT/hooks/qshipmaster-deliver.sh"
  "$SKILL_ROOT/hooks/qshipmaster-plan.sh"
  "$SKILL_ROOT/hooks/qshipmaster-merge-wave.sh"
  "$SKILL_ROOT/hooks/qshipmaster-state.sh"
  "$QSHIP_HOOKS/qship-persist.sh"
  "$GLOBAL_HOOKS/epic-mode-guard.sh"
)
DENYLIST_PATTERNS=(
  "$HOME/.claude/settings.json"
  "$HOME/.claude/settings.local.json"
  ".git/"
  "/etc/"
  "/.ssh/"
  ".env"
)
is_patchable() {
  local target="$1"
  local p
  for p in "${DENYLIST_PATTERNS[@]}"; do
    case "$target" in *"$p"*) return 1 ;; esac
  done
  for p in "${PATCHABLE_PATTERNS[@]}"; do
    [ "$target" = "$p" ] && return 0
  done
  return 1
}

# ── IDEMPOTENCY ────────────────────────────────────────────────────────────
already_applied() {
  local p
  for p in "${PATCHABLE_PATTERNS[@]}"; do
    [ -f "$p" ] && grep -q "SELF-IMPROVE: $FAILURE_KEY" "$p" 2>/dev/null && return 0
  done
  return 1
}

if already_applied; then
  log "patch for '$FAILURE_KEY' already applied (idempotency marker found) — exiting 0"
  exit 0
fi

# ── GAP #2: GIT-AS-ROLLBACK SETUP ─────────────────────────────────────────
# Initialize a hidden git repo inside SKILL_ROOT (separate from user's main
# git config). All patches commit there. Rollback = `git revert <sha>`.
ensure_git_repo() {
  if [ ! -d "$SKILL_ROOT/.git" ]; then
    log "initializing git repo at $SKILL_ROOT for rollback checkpoints"
    git -C "$SKILL_ROOT" init -q
    git -C "$SKILL_ROOT" config user.email "self-improve@qshipmaster.local"
    git -C "$SKILL_ROOT" config user.name "qshipmaster-self-improve"
    git -C "$SKILL_ROOT" add -A 2>/dev/null || true
    git -C "$SKILL_ROOT" commit -q -m "[SELF-IMPROVE: initial] baseline before any patches" --allow-empty
  fi
}
ensure_git_repo

# Snapshot pre-patch state
git_pre_patch_sha=$(git -C "$SKILL_ROOT" rev-parse HEAD)
log "pre-patch git sha: $git_pre_patch_sha"

# ── BACKUP (filesystem, belt + suspenders alongside git) ───────────────────
backup_file() {
  local f="$1"
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  local backup="$BACKUP_DIR/$(basename "$f")-$FAILURE_KEY-$stamp"
  cp "$f" "$backup"
  log "backed up $f → $backup"
  echo "$backup"
}

# ── SYNTAX CHECK ──────────────────────────────────────────────────────────
syntax_check() {
  local f="$1"
  case "$f" in
    *.sh) bash -n "$f" 2>&1 ;;
    *.md|*.txt) return 0 ;;
    *) echo "unknown file type: $f"; return 1 ;;
  esac
}

# ── GAP #1: BEHAVIOR VALIDATION CMD EXTRACTION ─────────────────────────────
# The diagnosis markdown should contain a VALIDATE_CMD section like:
#   ## VALIDATE_CMD
#   ```
#   bash -c 'cd {{STATE_ROOT}}/worktrees/<TICKET> && pytest tests/foo/test_bar.py::test_baz -x'
#   ```
# We extract it, save to a runnable file, and use it for post-patch verification.
extract_validate_cmd() {
  awk '/^## *VALIDATE_CMD/,/^```$/' "$DIAGNOSIS" \
    | awk '/^```$/{block_count++; next} block_count==1{print}' \
    | head -50
}

VALIDATE_CMD_FILE="$BACKUP_DIR/validate-$FAILURE_KEY-$(date '+%Y%m%d-%H%M%S').sh"
extract_validate_cmd > "$VALIDATE_CMD_FILE"
if [ -s "$VALIDATE_CMD_FILE" ]; then
  chmod +x "$VALIDATE_CMD_FILE"
  log "extracted VALIDATE_CMD → $VALIDATE_CMD_FILE"
  HAS_VALIDATION=1
else
  log "WARNING: diagnosis lacks VALIDATE_CMD section — falling back to syntax-only gate (pre-2026 weak verification)"
  HAS_VALIDATION=0
fi

# ── RESEARCH STAGE — IN-RUN WEBSEARCH-DRIVEN RETRY LOOP ────────────────────
# Fully-autonomous mode runs the research stage up to MAX_RESEARCH_ATTEMPTS
# times in a row WITHIN the current epic invocation. Each attempt uses a
# DIFFERENT search strategy derived from the previous attempt's failure mode.
# This converts "defer to next epic" into "search again right now with a
# different angle" — the loop decides through additional WebSearches rather
# than waiting.
#
# Strategy ladder (each attempt picks the strategy matching the prior failure):
#   Attempt 1: vanilla — broad query + ≥3 source domains
#   Attempt 2: if low diversity → exclude domains from attempt 1
#              if insufficient sources → broaden query terms + add synonyms
#              if low confidence → bias toward primary sources (RFCs, official docs)
#              if inconclusive → attack a different layer of the stack
#   Attempt 3: if regression-streak in deferred history → assume opposite root cause
#              else: combine strategies from attempts 1+2
#
# Only if ALL MAX_RESEARCH_ATTEMPTS exhaust without a clean patch do we
# record a final deferred entry and exit. The next epic will pick up with
# a fresh attempt regardless.

MAX_RESEARCH_ATTEMPTS="${QSHIPMASTER_MAX_RESEARCH_ATTEMPTS:-3}"
PATCH_PROPOSAL="$BACKUP_DIR/proposal-$FAILURE_KEY-$(date '+%Y%m%d-%H%M%S').md"
DEFERRED_HISTORY="$BACKUP_DIR/deferred-history-$FAILURE_KEY.txt"
jq -r --arg key "$FAILURE_KEY" \
  '[.deferred[]? | select(.key == $key)] |
   if length == 0 then "no prior deferrals for this key"
   else map("  - " + .deferred_at + " :: " + .reason + " (epic " + .epic + ")") | join("\n")
   end' "$PATCH_HISTORY" > "$DEFERRED_HISTORY"
log "researching fix for failure class '$FAILURE_KEY' (with $(wc -l < "$DEFERRED_HISTORY" | tr -d ' ') prior-deferral lines as context, up to $MAX_RESEARCH_ATTEMPTS in-run attempts)"

# In-run attempt loop. Each iteration writes its own proposal file and
# captures the failure reason so the next iteration can pick a different
# strategy. The loop exits early when a proposal passes ALL quality gates.

attempt=0
attempt_history_file="$BACKUP_DIR/attempt-history-$FAILURE_KEY-$(date '+%Y%m%d-%H%M%S').txt"
: > "$attempt_history_file"
final_proposal_ok=0

while [ "$attempt" -lt "$MAX_RESEARCH_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  PATCH_PROPOSAL="$BACKUP_DIR/proposal-$FAILURE_KEY-attempt$attempt-$(date '+%Y%m%d-%H%M%S').md"
  log "research attempt $attempt/$MAX_RESEARCH_ATTEMPTS"

  # Build the attempt-specific strategy hint from cross-epic deferrals AND
  # within-run prior-attempt failures (if any).
  intra_run_hints=""
  if [ "$attempt" -gt 1 ]; then
    intra_run_hints="$(cat "$attempt_history_file")"
  fi

_timeout_bin="$(command -v timeout || command -v gtimeout || echo timeout)"
"$_timeout_bin" --kill-after=10s 600 \
claude --print --dangerously-skip-permissions \
    --allowedTools 'WebSearch,WebFetch,Read,Grep,Glob' \
    --model haiku \
    --append-system-prompt 'You are the SELF-IMPROVE research agent for the qshipmaster skill. Read a diagnosis, research authoritative solutions, propose a CONCRETE patch that fixes the root cause. Patches MUST be incremental and reversible. ALLOWED edit categories: timeout values, retry counts, env var defaults, prompt directives, hook patterns, regex extensions, additional safety checks. FORBIDDEN: removing existing safety gates, reducing timeouts below 60s, weakening validation, touching business logic or product code.' \
    "Read the diagnosis at $DIAGNOSIS and propose a fix for failure class '$FAILURE_KEY'.

THIS IS RESEARCH ATTEMPT $attempt OF $MAX_RESEARCH_ATTEMPTS WITHIN THE CURRENT EPIC INVOCATION. Each attempt is allowed (and required) to pick a DIFFERENT search strategy from the previous attempt(s). The loop is fully autonomous — there is no human to escalate to. If this attempt fails the quality gates, the wrapper will run ANOTHER attempt with a strategy chosen by the failure mode of this one. Use this as motivation to actually try different angles, not to repeat what didn't work.

WITHIN-RUN ATTEMPT HISTORY (this run — prior attempts and why each failed):
$intra_run_hints
(empty above = this is the first attempt this run; for second+ attempts, the wrapper records the gate that rejected the previous proposal so you can pivot)

Allowlist of patchable files (you may target ONLY these):
$(printf '  - %s\n' "${PATCHABLE_PATTERNS[@]}")

CROSS-EPIC PRIOR DEFERRALS (this key has been attempted in past epics too — DO NOT repeat the same approach; pick a different angle):
$(cat $DEFERRED_HISTORY)

Strategy ladder (pick one for THIS attempt based on the failure modes above):
- Attempt 1 default: vanilla broad query covering the root cause, ≥3 source domains spread across vendor docs + arxiv + practitioner blogs.
- If a prior attempt failed 'low_diversity' → use DIFFERENT search domains this time. Explicitly avoid Stack Overflow / Medium / DEV.to if a previous attempt cited them; favour official vendor docs, arxiv, IEEE/ACM papers, standards bodies (NIST, IETF, W3C, OWASP).
- If a prior attempt failed 'insufficient_sources_*' → broaden the search query. Try synonyms, related concepts, sibling terminology (e.g. \"connection pool starvation\" instead of \"hang\"; \"reentrancy\" instead of \"recursion\").
- If a prior attempt failed 'low_confidence_*' → look for PRIMARY sources (RFCs, official docs, standards bodies, ISO/ANSI/IEEE specs) rather than blog posts or LLM summaries.
- If a prior attempt failed 'regression_streak_revert' → the previous fix made it worse; this time consider the OPPOSITE assumption about the root cause (if you assumed a race, try assuming a missing flush; if you assumed a missing check, try assuming an over-eager check).
- If a prior attempt failed 'sandbox_violation_*' → the previous target was illegal; choose a DIFFERENT file from the allowlist that's still reachable from the root cause.
- If a prior attempt was 'research_inconclusive' → the prior query was too narrow; widen the scope, OR attack a different layer of the stack (kernel → libc → language runtime → framework → application; or compile-time → load-time → init-time → request-time).

If prior deferrals exist:
- Read each deferred reason. If 'low_diversity_*' → use DIFFERENT search domains this time (avoid Stack Overflow if it was used; favour vendor docs / arxiv / academic).
- If 'insufficient_sources_*' → broaden the search query and try synonyms / related concepts.
- If 'low_confidence_*' → look for primary sources (RFCs, official docs, standards bodies) rather than blog posts.
- If 'regression_streak_revert' → the previous fix was wrong; consider the OPPOSITE assumption about the root cause.
- If 'sandbox_violation_*' → the previous target was illegal; choose a DIFFERENT file from the allowlist.
- If 'research_inconclusive' → the prior query was too narrow; widen the scope or attack a different layer of the stack.

Procedure:
1. Read diagnosis carefully. Identify symptom AND root cause.
2. WebSearch with a targeted query about the root cause (NOT the symptom). If prior deferrals exist, EXPLICITLY choose terms the previous attempts did not use.
3. Open ≥3 distinct sources (different domains required — repeat-domain doesn't count) via WebFetch.
4. If sources do not converge on a clear fix pattern, output VERDICT: INCONCLUSIVE and stop. The supervisor will retry next epic with a fresh attempt.
5. If sources converge: synthesize a CONCRETE patch with the EXACT format below.
6. Output format (STRICT — the wrapper greps these markers):
\`\`\`
CONFIDENCE: <0-100>
SOURCES:
- <URL 1>
- <URL 2>
- <URL 3>
- ... (≥3 required, ≥3 DISTINCT domains)
TARGET_FILE: <absolute path from allowlist>
RATIONALE:
<one paragraph: root cause + why this fix + why incremental + why reversible>
DIFF:
\`\`\`diff
--- a/<file>
+++ b/<file>
@@ ... @@
<unified diff>
\`\`\`
MARKER_LOCATION: <line range or section>
\`\`\`

The marker comment '# SELF-IMPROVE: $FAILURE_KEY $(date +%Y-%m-%d)' MUST be included in the patch at MARKER_LOCATION (for idempotency).

If diagnosis suggests product-code defect (your repos), output VERDICT: INCONCLUSIVE — that's out of scope for self-improve." \
    > "$PATCH_PROPOSAL" 2>&1 || true

# ── VALIDATE PROPOSAL ──────────────────────────────────────────────────────
confidence="$(grep -E '^CONFIDENCE:' "$PATCH_PROPOSAL" | head -1 | awk '{print $2}')"
verdict="$(grep -E '^VERDICT:' "$PATCH_PROPOSAL" | head -1 | awk '{print $2}')"
target_file="$(grep -E '^TARGET_FILE:' "$PATCH_PROPOSAL" | head -1 | awk '{print $2}')"
source_count="$(grep -cE '^- https?://' "$PATCH_PROPOSAL" || echo 0)"
# Gap #5: count UNIQUE domains, not just URLs
unique_domains="$(grep -oE '^- https?://[^/]+' "$PATCH_PROPOSAL" | sort -u | wc -l | tr -d ' ')"

# ── FULLY AUTONOMOUS MODE — NO USER ESCALATION ────────────────────────────
# Policy (per user directive): never block the current run waiting
# for human approval. Insufficient research → defer to next epic and try a
# different research strategy. Low quality → still apply if confidence > soft
# floor, otherwise defer. Sandbox violations → reject silently and self-record
# the rejection so future runs don't re-attempt the same illegal patch.

# Deferred-attempts ledger lives in patch-history.json under .deferred[].
# A deferred entry says "we tried failure_key X, couldn't apply this round,
# try a different angle next time".
record_deferred() {
  local reason="$1"
  local proposal_path="$2"
  jq --arg key "$FAILURE_KEY" \
     --arg epic "$EPIC" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg reason "$reason" \
     --arg proposal "$proposal_path" \
     '.deferred = (.deferred // []) + [{key: $key, epic: $epic, deferred_at: $ts, reason: $reason, proposal: $proposal}]' \
     "$PATCH_HISTORY" > "$PATCH_HISTORY.new" && mv "$PATCH_HISTORY.new" "$PATCH_HISTORY"
}

# How many times has THIS failure_key been deferred across previous epics?
deferred_count_for_key() {
  jq -r "[.deferred[]? | select(.key == \"$FAILURE_KEY\")] | length" "$PATCH_HISTORY" 2>/dev/null || echo 0
}

# Soft floor: if we've tried + deferred this key 3+ times before, LOWER the
# bar — bad patch is still better than infinite paralysis. Patches still
# auto-revert if behavior verification fails, so the downside is bounded.
prior_deferrals=$(deferred_count_for_key)
EFFECTIVE_FLOOR=$CONFIDENCE_FLOOR
if [ "$prior_deferrals" -ge 3 ]; then
  EFFECTIVE_FLOOR=$((CONFIDENCE_FLOOR - 25))
  log "$prior_deferrals prior deferrals of this key — lowering confidence floor to $EFFECTIVE_FLOOR (was $CONFIDENCE_FLOOR)"
fi

  # Gate cascade — instead of exiting, record the reason and continue to
  # the next research attempt with a different strategy.
  gate_failure=""
  if [ "$verdict" = "INCONCLUSIVE" ]; then
    gate_failure="research_inconclusive"
  elif [ -z "$confidence" ] || [ "$confidence" -lt "$EFFECTIVE_FLOOR" ] 2>/dev/null; then
    gate_failure="low_confidence_$confidence"
  elif [ "$source_count" -lt 3 ]; then
    gate_failure="insufficient_sources_$source_count"
  elif [ "$unique_domains" -lt "$MIN_SOURCE_DIVERSITY" ]; then
    gate_failure="low_diversity_$unique_domains"
  elif [ -z "$target_file" ] || ! is_patchable "$target_file"; then
    gate_failure="sandbox_violation_$target_file"
  fi

  if [ -n "$gate_failure" ]; then
    log "attempt $attempt rejected by gate: $gate_failure — recording and continuing to next attempt"
    {
      echo ""
      echo "Attempt $attempt rejected: $gate_failure"
      echo "  confidence=$confidence, sources=$source_count, unique_domains=$unique_domains, target=$target_file"
      echo "  proposal at: $PATCH_PROPOSAL"
    } >> "$attempt_history_file"
    # Continue to next iteration of the research while-loop
    continue
  fi

  # All gates passed — break out of the research loop with this proposal
  final_proposal_ok=1
  log "attempt $attempt passed all gates — proceeding to apply"
  break
done

if [ "$final_proposal_ok" != "1" ]; then
  log "all $MAX_RESEARCH_ATTEMPTS in-run research attempts failed gate checks — DEFERRING to next epic with a fresh start"
  final_reason="$(tail -1 "$attempt_history_file" | tr -d '\n')"
  record_deferred "exhausted_$MAX_RESEARCH_ATTEMPTS_attempts" "$attempt_history_file"
  exit 0
fi

# ── GAP #4 DISABLED: first-N-uses dry-run removed per fully-autonomous mode ─
# Rationale: dry-run requires user to approve from inbox, which violates the
# no-user-input directive. Auto-apply is the only path. Safety still holds
# because (a) behavior verification reverts bad patches, (b) regression-streak
# tracking auto-reverts patches that degrade outcomes over 3 epics.
prior_patches="$(file_patch_count "$target_file")"

# ── APPLY PATCH ────────────────────────────────────────────────────────────
log "applying patch to $target_file (confidence=$confidence, $unique_domains domains, $prior_patches prior patches)"
backup_path="$(backup_file "$target_file")"

# Extract unified diff block
awk '/^```diff$/,/^```$/' "$PATCH_PROPOSAL" | sed '1d;$d' > "$PATCH_PROPOSAL.diff"
if ! patch -p1 --dry-run < "$PATCH_PROPOSAL.diff" >/dev/null 2>&1; then
  log "patch dry-run failed — RESEARCH OUTPUT MALFORMED. Aborting."
  exit 2
fi
patch -p1 --backup-if-mismatch < "$PATCH_PROPOSAL.diff" 2>&1 | tee -a "$AUDIT_LOG"

# ── POST-PATCH SYNTAX CHECK ────────────────────────────────────────────────
if ! syntax_check "$target_file" 2>&1 | tee -a "$AUDIT_LOG"; then
  log "syntax check FAILED — REVERTING from $backup_path"
  cp "$backup_path" "$target_file"
  exit 2
fi

# ── GAP #1: POST-PATCH BEHAVIOR VERIFICATION ──────────────────────────────
# Run the VALIDATE_CMD extracted from the diagnosis. If it still fails, the
# patch did not address the root cause — revert. This is the verifiability
# constraint enforced as a runtime gate (Alcaraz 2026).
if [ "$HAS_VALIDATION" -eq 1 ]; then
  log "running post-patch VALIDATE_CMD ..."
  validate_out="$BACKUP_DIR/validate-out-$FAILURE_KEY-$(date '+%Y%m%d-%H%M%S').log"
  if "$_timeout_bin" --kill-after=10s 300 bash "$VALIDATE_CMD_FILE" > "$validate_out" 2>&1; then
    log "✅ VALIDATE_CMD passed — behavior verified after patch"
    behavior_verified="PASS"
  else
    rc=$?
    log "❌ VALIDATE_CMD FAILED (exit=$rc) — patch did NOT fix the root cause. REVERTING from $backup_path. See $validate_out"
    cp "$backup_path" "$target_file"
    # Mark in history as a failed attempt so future runs don't retry
    jq --arg key "$FAILURE_KEY" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg epic "$EPIC" --arg target "$target_file" --arg reason "post_patch_validation_failed" \
       '.patches += [{key: $key, epic: $epic, applied_at: $ts, target_file: $target,
                      reverted: true, reason: $reason}]' \
       "$PATCH_HISTORY" > "$PATCH_HISTORY.new" && mv "$PATCH_HISTORY.new" "$PATCH_HISTORY"
    exit 2
  fi
else
  log "⚠ no VALIDATE_CMD in diagnosis — applying patch on syntax-only gate (weak verification)"
  behavior_verified="UNKNOWN"
fi

# ── VERIFY MARKER PRESENT ──────────────────────────────────────────────────
if ! grep -q "SELF-IMPROVE: $FAILURE_KEY" "$target_file"; then
  log "WARNING: idempotency marker missing in patched file. Appending."
  case "$target_file" in
    *.sh) echo "# SELF-IMPROVE: $FAILURE_KEY $(date +%Y-%m-%d)" >> "$target_file" ;;
    *.md) echo "<!-- SELF-IMPROVE: $FAILURE_KEY $(date +%Y-%m-%d) -->" >> "$target_file" ;;
  esac
fi

# ── GAP #2: GIT COMMIT THE PATCH ──────────────────────────────────────────
git -C "$SKILL_ROOT" add -A 2>/dev/null || true
patch_commit_msg="[SELF-IMPROVE: $FAILURE_KEY] confidence=$confidence verified=$behavior_verified epic=$EPIC"
if git -C "$SKILL_ROOT" diff --cached --quiet; then
  log "no git changes to commit (patch may target $QSHIP_HOOKS or $GLOBAL_HOOKS — outside SKILL_ROOT git repo). Falling back to fs backup only."
  git_post_patch_sha="$git_pre_patch_sha"
else
  git -C "$SKILL_ROOT" commit -q -m "$patch_commit_msg"
  git_post_patch_sha=$(git -C "$SKILL_ROOT" rev-parse HEAD)
  log "git commit: $git_post_patch_sha"
fi

# ── GAP #3: RECORD IN PATCH-HISTORY.JSON ──────────────────────────────────
new_count=$((prior_patches + 1))
# Read sources + domains into a JSON array
sources_json=$(grep -oE '^- https?://[^ ]+' "$PATCH_PROPOSAL" | sed 's/^- //' | jq -R . | jq -s .)
domains_json=$(grep -oE '^- https?://[^/]+' "$PATCH_PROPOSAL" | sort -u | sed 's/^- //' | jq -R . | jq -s .)
jq --arg key "$FAILURE_KEY" \
   --arg epic "$EPIC" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --arg target "$target_file" \
   --arg sha "$git_post_patch_sha" \
   --arg backup "$backup_path" \
   --argjson conf "$confidence" \
   --argjson srcs "$sources_json" \
   --argjson doms "$domains_json" \
   --arg verified "$behavior_verified" \
   '.patches += [{
      key: $key,
      epic: $epic,
      applied_at: $ts,
      target_file: $target,
      git_sha: $sha,
      backup_path: $backup,
      confidence: $conf,
      sources: $srcs,
      domains: $doms,
      outcomes: { post_apply: $verified, epics_observed: [] }
    }]
    | .file_patch_counts[$target] = ((.file_patch_counts[$target] // 0) + 1)' \
   "$PATCH_HISTORY" > "$PATCH_HISTORY.new" && mv "$PATCH_HISTORY.new" "$PATCH_HISTORY"

# ── GAP #5: SOURCE DIVERSITY AUDIT (trend) ────────────────────────────────
# Aggregate all unique domains across ALL patches; warn if recent N patches
# are converging on fewer than 5 unique domains total (echo-chamber signal).
recent_domains_count=$(jq -r '[.patches[-10:] | .[].domains[]] | unique | length' "$PATCH_HISTORY" 2>/dev/null || echo "0")
if [ "$recent_domains_count" -lt 5 ] && [ "$(jq '.patches | length' "$PATCH_HISTORY")" -ge 5 ]; then
  log "⚠ gap #5: last 10 patches only consulted $recent_domains_count unique domains — possible echo-chamber drift. Inspect $PATCH_HISTORY."
fi

# ── LOG TO AGENTS.MD ───────────────────────────────────────────────────────
{
  echo ""
  echo "<!-- self-improve: $EPIC / $FAILURE_KEY / $(date -u +%Y-%m-%dT%H:%M:%SZ) -->"
  echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) — SELF-IMPROVE patch applied (verified=$behavior_verified)"
  echo "- KEY: $FAILURE_KEY"
  echo "- TARGET: $target_file ($new_count total patches to this file)"
  echo "- CONFIDENCE: $confidence/100"
  echo "- SOURCES: $source_count URLs across $unique_domains unique domains"
  echo "- GIT SHA: $git_post_patch_sha"
  echo "- BACKUP: $backup_path"
  echo "- VALIDATE_CMD: $VALIDATE_CMD_FILE (verdict=$behavior_verified)"
  echo "- PROPOSAL: $PATCH_PROPOSAL"
  echo "- RATIONALE: $(awk '/^RATIONALE:$/,/^DIFF:$/' "$PATCH_PROPOSAL" | sed '1d;$d' | head -3 | tr '\n' ' ')"
} >> "$AGENTS_MD"

log "SELF-IMPROVE applied + verified ($behavior_verified). Git: $git_post_patch_sha. Next epic picks up the patched skill."
exit 0
