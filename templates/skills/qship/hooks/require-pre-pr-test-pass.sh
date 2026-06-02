#!/bin/bash
# PreToolUse hook: block `gh pr create` until Step 12.0 has produced a fresh
# per-repo "tests passed" flag file. Companion to qship pipeline-steps.md
# §12.0 — "Final test pass before PR creation".
#
# Wire in ~/.claude/settings.json under hooks.PreToolUse for matcher "Bash".
# Input on stdin: {"tool_input": {"command": "<the bash command>"}}.
# Output:
#   allow → {"continue": true}
#   block → {"decision": "block", "reason": "<why>"}
#
# Blocks when the command matches `gh pr create` AND the ticket dir has either:
#   - no flag file at  {{STATE_ROOT}}/worktrees/<TICKET>/phase4-tests-passed.<repo>.flag
#   - a stale flag (older than QSHIP_TEST_FLAG_FRESHNESS_MIN, default 60 min)
#   - a stale flag relative to the most recent commit on the branch
#     (i.e., new commits landed after tests were run)
#
# When all flags are present and fresh, allows the PR.
#
# Disable with QSHIP_SKIP_PRE_PR_TEST_GATE=1 (escape hatch for hand-PRs).

set -eo pipefail

WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
FRESHNESS_MIN="${QSHIP_TEST_FLAG_FRESHNESS_MIN:-60}"

emit_continue() { echo '{"continue": true}'; exit 0; }
emit_block() { jq -Rn --arg r "$1" '{decision: "block", reason: $r}'; exit 0; }

# Honor the escape hatch.
[ -n "$QSHIP_SKIP_PRE_PR_TEST_GATE" ] && emit_continue

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Only intercept gh pr create. Other gh commands (pr view, pr checks, pr comment) pass.
case "$cmd" in
  *"gh pr create"*) ;;
  *) emit_continue ;;
esac

# Identify the ticket from the command (the same {{JIRA_PROJECT_KEY}}-... extraction the other
# hooks use). If no ticket id is found in the command, the user is creating a
# PR by hand — let it through; this hook only enforces qship-managed PRs.
ticket_id=$(echo "$cmd" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)
[ -z "$ticket_id" ] && emit_continue

ticket_dir=""
for path in \
    "${WORKTREE_ROOT}/${ticket_id}" \
    "${WORKTREE_ROOT}/${ticket_id}-final" \
    "${WORKTREE_ROOT}/${ticket_id}-integration"; do
  if [ -d "$path" ]; then
    ticket_dir="$path"
    break
  fi
done

# No qship worktree → not our job.
[ -z "$ticket_dir" ] && emit_continue

# Find every per-repo subdir in the ticket dir that's a git checkout.
repos=()
for sub in "$ticket_dir"/*/; do
  [ -d "${sub}.git" ] && repos+=("$(basename "$sub")")
done
# A worktree may be a single-repo layout (ticket_dir itself is the checkout).
if [ ${#repos[@]} -eq 0 ] && [ -d "$ticket_dir/.git" ]; then
  repos+=("$(basename "$ticket_dir")")
fi

# No repos to verify → can't enforce; let it through.
[ ${#repos[@]} -eq 0 ] && emit_continue

# Check each repo has a fresh flag file.
missing=()
stale=()
behind_head=()

for repo in "${repos[@]}"; do
  flag="${ticket_dir}/phase4-tests-passed.${repo}.flag"

  if [ ! -f "$flag" ]; then
    missing+=("$repo")
    continue
  fi

  # Freshness check (mtime, in minutes).
  age_min=$(( ( $(date +%s) - $(stat -f %m "$flag" 2>/dev/null || stat -c %Y "$flag") ) / 60 ))
  if [ "$age_min" -gt "$FRESHNESS_MIN" ]; then
    stale+=("${repo} (${age_min}min old, threshold ${FRESHNESS_MIN}min)")
    continue
  fi

  # Behind-head check: if the branch has commits newer than the flag, fail.
  repo_path="${ticket_dir}/${repo}"
  [ ! -d "$repo_path/.git" ] && repo_path="$ticket_dir"
  if [ -d "$repo_path/.git" ]; then
    flag_mtime=$(stat -f %m "$flag" 2>/dev/null || stat -c %Y "$flag")
    head_mtime=$(cd "$repo_path" && git log -1 --format=%ct 2>/dev/null || echo 0)
    if [ "$head_mtime" -gt "$flag_mtime" ]; then
      behind_head+=("${repo} (HEAD commit is newer than the test flag; tests must re-run)")
    fi
  fi
done

# Compose block message if anything failed.
if [ ${#missing[@]} -gt 0 ] || [ ${#stale[@]} -gt 0 ] || [ ${#behind_head[@]} -gt 0 ]; then
  msg="qship Step 12.0 gate: full test suite has not been verified for this ticket before \`gh pr create\`."
  [ ${#missing[@]} -gt 0 ] && msg="${msg} Missing flag(s): ${missing[*]}."
  [ ${#stale[@]} -gt 0 ] && msg="${msg} Stale flag(s): ${stale[*]}."
  [ ${#behind_head[@]} -gt 0 ] && msg="${msg} Branch advanced after tests ran: ${behind_head[*]}."
  msg="${msg} Run pytest tests/ -v in each affected repo until green, then \`touch ${ticket_dir}/phase4-tests-passed.<repo>.flag\` per repo. See pipeline-steps.md §12.0. To bypass for a hand-PR set QSHIP_SKIP_PRE_PR_TEST_GATE=1."
  emit_block "$msg"
fi

emit_continue
