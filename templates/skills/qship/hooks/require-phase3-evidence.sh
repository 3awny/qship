#!/bin/bash
# PreToolUse hook: block Phase 4 tool calls (PR create / epic branch push) when
# phase3-evidence.md doesn't satisfy the API/UI split-evidence contract for the
# ticket's pipeline-context.json.
#
# Wire in ~/.claude/settings.json under hooks.PreToolUse for matcher "Bash".
# Input on stdin: {"tool_input": {"command": "<the bash command>"}}.
# Output:
#   allow → {"continue": true}
#   block → {"decision": "block", "reason": "<why>"}
#
# Blocks when the command matches one of:
#   gh pr create ...                     (epic branch referenced in args)
#   git push ... {{JIRA_PROJECT_KEY}}-...                 (epic branch push)
#   gh pr comment ... {{JIRA_PROJECT_KEY}}-...            (PR comment on an epic PR)
# Does not block other Bash commands.
#
# Evidence validation is delegated to qship-evidence-lib.sh so it stays in sync
# with the Stop hook.

set -eo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./qship-evidence-lib.sh
source "$HOOK_DIR/qship-evidence-lib.sh"

WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"

emit_continue() { echo '{"continue": true}'; exit 0; }
emit_block() { jq -Rn --arg r "$1" '{decision: "block", reason: $r}'; exit 0; }

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Only intercept Phase-4 verbs.
case "$cmd" in
  *"gh pr create"*|*"git push"*" {{JIRA_PROJECT_KEY}}-"*|*"gh pr comment"*) ;;
  *) emit_continue ;;
esac

# Extract epic id; if none, don't block unrelated work.
epic_id=$(echo "$cmd" | grep -oE '{{JIRA_PROJECT_KEY}}-[0-9]+' | head -1 || true)
[ -z "$epic_id" ] && emit_continue

# Locate the ticket dir (canonical + a couple of common variants).
ticket_dir=""
for path in \
    "${WORKTREE_ROOT}/${epic_id}" \
    "${WORKTREE_ROOT}/${epic_id}-final" \
    "${WORKTREE_ROOT}/${epic_id}-integration"; do
  if [ -d "$path" ]; then
    ticket_dir="$path"
    break
  fi
done

if [ -z "$ticket_dir" ]; then
  # No qship worktree → can't validate; let it through. User is doing manual PR work.
  emit_continue
fi

evidence="$ticket_dir/phase3-evidence.md"

# Missing evidence file but pipeline-context says E2E was required → block.
if err=$(phase3_has_missing_e2e "$epic_id" "$ticket_dir" 2>&1 >/dev/null); then
  if [ -n "$err" ]; then
    emit_block "qship Gate G3: ${err}  Expected at ${evidence}. Run /qe2etest (which delegates UI to /qmanualt + Playwright) and capture test-results/playwright-results.json + trace.zip, or add a 'no ui surface: <reason>' / 'no api surface: <reason>' rationale."
  fi
fi

# Otherwise validate the evidence content against the split-evidence contract.
if err=$(validate_phase3_evidence "$epic_id" "$ticket_dir" 2>&1 >/dev/null); then
  [ -z "$err" ] && emit_continue
  emit_block "qship Gate G3 blocked: ${err}"
fi

emit_continue
