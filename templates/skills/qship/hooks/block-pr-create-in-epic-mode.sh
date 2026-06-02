#!/bin/bash
# block-pr-create-in-epic-mode.sh — PreToolUse hook for Bash.
#
# Hard-stops `gh pr create` and `git push` to ticket branches when running
# inside an EPIC_MODE qship worker. Per qshipmaster contract, ONE consolidated
# PR per repo is created at the deliver step — workers must NOT open per-ticket
# PRs even if their /qship skill body says to. The system-prompt directive in
# qship-persist.sh tells workers to skip Phase 4 PR creation, but the directive
# is advisory; this hook is the belt-and-braces enforcement.
#
# Wired in ~/.claude/settings.json or settings.local.json under:
#   "hooks": {
#     "PreToolUse": [
#       { "matcher": "Bash", "hooks": [
#         { "type": "command", "command": "bash ~/.claude/skills/qship/hooks/block-pr-create-in-epic-mode.sh" }
#       ]}
#     ]
#   }
#
# Exit codes:
#   0 — allow the tool call
#   2 — block, print reason to stderr (Claude Code will surface to the model)

set -eo pipefail

# Only fire in EPIC_MODE — outside an epic, /qship SHOULD create per-ticket PRs.
if [ "${EPIC_MODE:-false}" != "true" ]; then
    exit 0
fi

# Read the tool input JSON from stdin.
input="$(cat)"

# Extract the bash command. Use jq if available, fall back to grep.
cmd=""
if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
fi
if [ -z "$cmd" ]; then
    # Fallback: scan for the command field in JSON.
    cmd=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null || echo "")
fi

[ -z "$cmd" ] && exit 0

# Block patterns. Use grep -E with word-ish boundaries to avoid false positives
# on substrings like "create" inside other commands.
block_reason=""
if printf '%s' "$cmd" | grep -qE '(^|[^a-zA-Z0-9_-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
    block_reason="gh pr create is forbidden in EPIC_MODE workers — qshipmaster opens ONE consolidated PR per repo at the deliver step. Skip Phase 4 PR creation; commit your work, write phase1-summary.md + phase1-complete.flag, exit cleanly."
elif printf '%s' "$cmd" | grep -qE '(^|[^a-zA-Z0-9_-])gh[[:space:]]+pr[[:space:]]+(edit|review|merge)([[:space:]]|$)'; then
    block_reason="gh pr <edit|review|merge> is forbidden in EPIC_MODE workers — only the orchestrator's deliver step touches PRs."
elif printf '%s' "$cmd" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+push([[:space:]]|$)'; then
    # Allow ONLY pushes to the epic branch (qshipmaster-deliver.sh path);
    # block pushes to ticket-scoped branches that workers should never push.
    if printf '%s' "$cmd" | grep -qE '{{JIRA_PROJECT_KEY}}-[0-9]+-(?!.*epic)' 2>/dev/null \
       || printf '%s' "$cmd" | grep -qE 'origin[[:space:]]+{{JIRA_PROJECT_KEY}}-[0-9]+'; then
        block_reason="git push of a ticket branch is forbidden in EPIC_MODE — the orchestrator pushes the consolidated epic branch at the deliver step."
    fi
fi

if [ -n "$block_reason" ]; then
    {
        echo "BLOCKED by qship EPIC_MODE hook:"
        echo ""
        echo "$block_reason"
        echo ""
        echo "What to do instead:"
        echo "  1. Confirm your implementation is committed locally on the ticket branch."
        echo "  2. Write {{STATE_ROOT}}/worktrees/\${TICKET}/phase1-summary.md (1 paragraph: what you implemented, files touched, AC covered)."
        echo "  3. Touch {{STATE_ROOT}}/worktrees/\${TICKET}/phase1-complete.flag"
        echo "  4. Stop. The orchestrator will merge your branch into the epic branch, run wave-level Phase 2/3 review, and open the consolidated PR."
        echo ""
        echo "Command attempted: $(printf '%s' "$cmd" | head -c 200)"
    } >&2
    exit 2
fi

exit 0
