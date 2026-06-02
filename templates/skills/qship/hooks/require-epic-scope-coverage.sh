#!/bin/bash
# PreToolUse hook: block PR creation / epic-branch push when delivered scope
# does not match the planned scope captured at qship-persist.sh startup.
#
# Wire in ~/.claude/settings.json under hooks.PreToolUse for matcher "Bash".
# Input on stdin: {"tool_input": {"command": "<the bash command>"}}.
# Output:
#   allow → exit 0 with {"continue": true}
#   block → exit 0 with {"decision": "block", "reason": "<why>"}
#
# Triggers when the command is one of:
#   gh pr create ...
#   gh pr edit ... --body ...
#   git push ... {{JIRA_PROJECT_KEY}}-...
#   gh pr comment ... {{JIRA_PROJECT_KEY}}-...
#
# Verification:
#   1. Read {{STATE_ROOT}}/worktrees/<EPIC>/expected-children.txt — list of child
#      ticket IDs captured by the wrapper before the orchestrator started.
#      Source of truth: cannot be tampered with by the orchestrator (written
#      by a separate process before the first claude -p iteration).
#   2. For each child:
#        a. Check a branch matching `<CHILD>-*` exists in at least one of
#           any repo in repos.json, AND
#        b. That branch has ≥1 commit ahead of develop.
#      → If any child fails → block.
#   3. If {{STATE_ROOT}}/worktrees/<EPIC>/canaries.json exists, additionally
#      verify each canary string appears in at least one branch's diff vs
#      develop. Belt-and-braces — catches stub commits.
#
# Graceful degradation: if expected-children.txt is missing (e.g. wrapper
# was launched without manifest fetch, or this is a single-story ticket),
# the hook is a no-op. Existing require-phase3-evidence.sh still runs.

set -eo pipefail

WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
REPO_ROOTS=(
  "{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}"
  "{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}"
  "{{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}"
)

emit_continue() { echo '{"continue": true}'; exit 0; }
emit_block() { jq -Rn --arg r "$1" '{decision: "block", reason: $r}'; exit 0; }

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)

case "$cmd" in
  *"gh pr create"*|*"gh pr edit"*|*"git push"*" {{JIRA_PROJECT_KEY}}-"*|*"gh pr comment"*) ;;
  *) emit_continue ;;
esac

# Pull the candidate epic id out of the command. Branch / PR commands embed
# it via either the branch name ({{JIRA_PROJECT_KEY}}-NNN-...) or the explicit --base/--head.
epic_id=$(echo "$cmd" | grep -oE '{{JIRA_PROJECT_KEY}}-[0-9]+' | head -1 || true)
[ -z "$epic_id" ] && emit_continue

manifest="$WORKTREE_ROOT/$epic_id/expected-children.txt"
canary_file="$WORKTREE_ROOT/$epic_id/canaries.json"

# No manifest = single-story run or pre-fetch skipped. Don't block; phase3
# evidence hook still applies.
[ -s "$manifest" ] || emit_continue

# Read expected children, ignoring blank lines. macOS ships bash 3.2 which
# lacks `mapfile`, so use a portable while-read loop.
expected=()
while IFS= read -r line; do
  expected+=("$line")
done < <(grep -E '^{{JIRA_PROJECT_KEY}}-[0-9]+$' "$manifest" | sort -u)
[ "${#expected[@]}" -eq 0 ] && emit_continue

missing_branches=()
empty_branches=()
missing_canaries=()

for child in "${expected[@]}"; do
  found_branch=""
  found_repo=""
  for repo in "${REPO_ROOTS[@]}"; do
    [ -d "$repo/.git" ] || continue
    # Look for branch (local OR remote-tracking) whose name starts with the child id.
    branch=$(git -C "$repo" for-each-ref --format='%(refname:short)' \
      "refs/heads/${child}-*" "refs/remotes/origin/${child}-*" 2>/dev/null | head -1)
    if [ -n "$branch" ]; then
      found_branch="$branch"
      found_repo="$repo"
      break
    fi
  done

  if [ -z "$found_branch" ]; then
    missing_branches+=("$child")
    continue
  fi

  # Count commits ahead of develop. If the branch is remote-only, compare against origin/develop.
  commits=$(git -C "$found_repo" rev-list --count "develop..$found_branch" 2>/dev/null || echo 0)
  if [ "$commits" -eq 0 ]; then
    # Try origin/develop as base in case develop isn't local.
    commits=$(git -C "$found_repo" rev-list --count "origin/develop..$found_branch" 2>/dev/null || echo 0)
  fi
  if [ "$commits" -eq 0 ]; then
    empty_branches+=("$child ($found_branch)")
  fi
done

# Canary check (only if canaries.json exists).
if [ -s "$canary_file" ]; then
  while IFS=$'\t' read -r child canary; do
    [ -z "$child" ] && continue
    found=0
    for repo in "${REPO_ROOTS[@]}"; do
      [ -d "$repo/.git" ] || continue
      branch=$(git -C "$repo" for-each-ref --format='%(refname:short)' \
        "refs/heads/${child}-*" "refs/remotes/origin/${child}-*" 2>/dev/null | head -1)
      [ -z "$branch" ] && continue
      if git -C "$repo" log "develop..$branch" -p 2>/dev/null | grep -qF "$canary"; then
        found=1
        break
      fi
      if git -C "$repo" log "origin/develop..$branch" -p 2>/dev/null | grep -qF "$canary"; then
        found=1
        break
      fi
    done
    [ "$found" -eq 0 ] && missing_canaries+=("$child (canary $canary)")
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$canary_file")
fi

# If everything passes, allow.
if [ "${#missing_branches[@]}" -eq 0 ] && \
   [ "${#empty_branches[@]}" -eq 0 ] && \
   [ "${#missing_canaries[@]}" -eq 0 ]; then
  emit_continue
fi

# Build a clear, actionable block reason.
{
  echo "Epic scope coverage check FAILED for $epic_id."
  echo "Phase 4 (PR create / push / comment) is blocked until every child story"
  echo "in the planned manifest has real implementation."
  echo
  if [ "${#missing_branches[@]}" -gt 0 ]; then
    echo "Children with NO branch in any repo:"
    for c in "${missing_branches[@]}"; do echo "  - $c"; done
    echo
  fi
  if [ "${#empty_branches[@]}" -gt 0 ]; then
    echo "Children with a branch but ZERO commits ahead of develop:"
    for c in "${empty_branches[@]}"; do echo "  - $c"; done
    echo
  fi
  if [ "${#missing_canaries[@]}" -gt 0 ]; then
    echo "Children whose canary sentinel is absent from the diff (likely stub):"
    for c in "${missing_canaries[@]}"; do echo "  - $c"; done
    echo
  fi
  echo "Manifest: $manifest"
  echo "DO NOT rationalize these as 'deferred', 'out of scope', or 'no UI surface'."
  echo "Implement the missing children. Re-run the persist loop with the same epic ID."
} | {
  reason=$(cat)
  emit_block "$reason"
}
