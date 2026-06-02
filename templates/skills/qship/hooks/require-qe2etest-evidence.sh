#!/bin/bash
# PreToolUse hook: enforce I1 + I8 invariants — /qe2etest is the ONLY accepted
# Phase 3 evidence for both wave-level and epic-level review. Block PR creation
# / push when wave-N-phase23-evidence.md or epic-phase3-evidence.md fails the
# validator in qship-evidence-lib.sh::validate_qe2etest_evidence.
#
# This is defense-in-depth: the orchestrator (qshipmaster-run.sh,
# qshipmaster-deliver.sh) ALSO calls the validator inline, but if the user
# manually pushes/PRs an epic branch (or a different orchestrator is used),
# this hook catches the gap at tool-call time.
#
# Wire in ~/.claude/settings.json under hooks.PreToolUse for matcher "Bash"
# alongside the existing require-phase3-evidence.sh and require-phase3-critic.sh.
#
# Input on stdin: standard Claude Code hook envelope.
# Output: {"continue": true} OR {"decision": "block", "reason": "<why>"}.
#
# Triggers on the same Phase-4 verbs as the sister hook:
#   gh pr create ... (epic branch in args or current branch)
#   git push ... {{JIRA_PROJECT_KEY}}-...-... (epic-style branch ref)
#   gh pr comment <epic-PR-url> ...
#
# Graceful fallback: if no epic-state-file can be located for the branch ref,
# this hook does NOT block — that's the existing require-phase3-evidence.sh's
# job (per-ticket gate). We only fire on epic-level state files.

set -eo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./qship-evidence-lib.sh
source "$HOOK_DIR/qship-evidence-lib.sh"

emit_continue() { echo '{"continue": true}'; exit 0; }
emit_block() { jq -Rn --arg r "$1" '{decision: "block", reason: $r}'; exit 0; }

# Read full hook envelope.
hook_input=$(cat 2>/dev/null || echo '{}')
cmd=$(echo "$hook_input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Only intercept Phase-4 verbs on epic branches. Tighter pattern than the
# sister hook to avoid false positives on commands that merely MENTION
# `gh pr create` inside a heredoc / echo / `cat >>` body (e.g. when capturing
# AGENTS.md learnings that quote those strings). The match must be the actual
# command verb at the START of the command line, after any env-var prefix.
#
# Stripping env-var assignments + leading whitespace, then word-boundary match:
clean_cmd=$(echo "$cmd" | sed -E 's/^[[:space:]]*([A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+)*//' | head -c 200)

# Use grep -E with word anchors; only the LEADING command words count.
if ! echo "$clean_cmd" | grep -qE '^(gh pr create\b|gh pr comment\b|git push\b)'; then
  emit_continue
fi

# Additional safety: heredoc / cat-with-redirect / echo patterns shouldn't
# trigger. If the command line contains an obvious heredoc marker (<<EOF or
# similar) AND the trigger verb appears AFTER the heredoc start, it's content.
if echo "$cmd" | grep -qE '<<-?[[:space:]]*['"'"'"]?[A-Z_]+['"'"'"]?'; then
  # Heredoc present — verify the verb is BEFORE the heredoc start.
  verb_pos=$(echo "$cmd" | grep -boE '^(gh pr create|gh pr comment|git push)' | head -1 | cut -d: -f1)
  heredoc_pos=$(echo "$cmd" | grep -boE '<<-?[[:space:]]*['"'"'"]?[A-Z_]+' | head -1 | cut -d: -f1)
  if [ -n "$heredoc_pos" ] && [ -n "$verb_pos" ] && [ "$verb_pos" -gt "$heredoc_pos" ]; then
    emit_continue
  fi
fi

# Extract epic-style branch name ({{JIRA_PROJECT_KEY}}-NNN-...). Fall through if we can't.
epic_id=$(echo "$cmd" | grep -oE '{{JIRA_PROJECT_KEY}}-[0-9]+' | head -1 || true)
[ -z "$epic_id" ] && emit_continue

EPIC_DIR_ROOT="${QSHIP_EPIC_ROOT:-{{STATE_ROOT}}-epic}"
epic_dir="${EPIC_DIR_ROOT}-${epic_id}"

# If the epic-state file doesn't exist, this isn't an epic PR — let the
# per-ticket hook handle it.
state_file="$epic_dir/state.json"
[ ! -f "$state_file" ] && emit_continue

# Determine the wave plan from state.json. For each shipped wave, validate
# its wave-N-phase23-evidence.md. Also validate epic-phase3-evidence.md
# (or epic-qe2etest.log).
base_branch=$(jq -r '.base_branch // "develop"' "$state_file")
repos=$(jq -r '.repos[]?' "$state_file")
primary_repo=$(echo "$repos" | head -1)
repo_root="${REPO_ROOT:-{{CODEBASE_ROOT}}}"
repo_dir="$repo_root/$primary_repo"

# Walk waves and validate each shipped wave's evidence.
errors=()
wave_count=$(jq -r '.waves | length' "$state_file")
for ((i=0; i<wave_count; i++)); do
  wave_status=$(jq -r ".waves[$i].status" "$state_file")
  [ "$wave_status" != "shipped" ] && continue
  wave_n=$((i+1))
  wave_evidence="$epic_dir/wave-${wave_n}-phase23-evidence.md"
  if ! validate_qe2etest_evidence "$wave_evidence" "wave $wave_n" "${base_branch}..HEAD" "$repo_dir" 2>/tmp/qe2etest-hook.err; then
    errors+=("$(cat /tmp/qe2etest-hook.err)")
  fi
done

# Epic-end evidence — accept either epic-qe2etest.log or epic-phase3-evidence.md.
epic_evidence=""
for candidate in "$epic_dir/epic-qe2etest.log" "$epic_dir/epic-phase3-evidence.md"; do
  if [ -s "$candidate" ]; then
    epic_evidence="$candidate"
    break
  fi
done

if [ -z "$epic_evidence" ]; then
  errors+=("epic: neither epic-qe2etest.log nor epic-phase3-evidence.md exists or is non-empty in $epic_dir")
else
  if ! validate_qe2etest_evidence "$epic_evidence" "epic" "${base_branch}..HEAD" "$repo_dir" 2>/tmp/qe2etest-hook.err; then
    errors+=("$(cat /tmp/qe2etest-hook.err)")
  fi
fi

if [ "${#errors[@]}" -gt 0 ]; then
  reason="BLOCKED: I1/I8 invariant violation — /qe2etest evidence missing or invalid for epic ${epic_id}. Fix the evidence file(s) and retry. Specific failures:"
  for e in "${errors[@]}"; do
    reason+=$'\n  - '"$e"
  done
  reason+=$'\n\nThis is the gate that would have caught {{JIRA_PROJECT_KEY}}-EX06 epic-end Phase 3 (empty table) and waves 1/2/3/5 (pytest cited as Phase 3) before they shipped. Re-run /qe2etest against the affected branch tip and append the canonical "## Phase 3 — /qe2etest evidence" section.'
  emit_block "$reason"
fi

emit_continue
