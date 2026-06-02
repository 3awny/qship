#!/usr/bin/env bash
# first-run-check.sh — runs on every Claude Code SessionStart while the qship
# plugin is installed.  Cheap idempotent check: if the user has never
# configured qship (marker file missing), print a one-shot prompt directing
# them at `/qship:configure`.  Otherwise no-op silently.
#
# Per the Claude Code plugin docs (https://code.claude.com/docs/en/plugins),
# this is the recommended pattern for first-run setup since `plugin.json` does
# not yet support a `postInstall` lifecycle hook (see anthropics/claude-code
# issue #11240 — closed as duplicate, still not shipped).
#
# Do NOT block the session here.  Soft prompt only — the user may have
# legitimate reasons to use the plugin partially configured (e.g. they ran
# `setup.sh` manually and skipped touching the marker file).
#
# Env vars available in this context:
#   $CLAUDE_PLUGIN_ROOT — absolute path to the installed plugin directory
#   $HOME               — user's home directory
#   no others guaranteed; do not rely on $USER, $CWD, etc.

set -uo pipefail

MARKER="$HOME/.claude/skills/qship/.configured"
SKILLS_ROOT="$HOME/.claude/skills"

# Already configured → silent exit.  Most-common path; keep it fast.
if [ -f "$MARKER" ]; then
    exit 0
fi

# Heuristic: if the user has a fully-rendered qship SKILL.md without
# unresolved `{{PLACEHOLDERS}}`, treat that as configured even without the
# marker (handles users who installed via git-clone + setup.sh on an older
# version that didn't touch the marker).
QSHIP_SKILL="$SKILLS_ROOT/qship/SKILL.md"
if [ -f "$QSHIP_SKILL" ] && ! grep -q '{{[A-Z_]\+}}' "$QSHIP_SKILL" 2>/dev/null; then
    # Looks configured — back-fill the marker for future sessions.
    mkdir -p "$(dirname "$MARKER")"
    : > "$MARKER"
    exit 0
fi

# First run.  Print a one-shot setup prompt that Claude Code surfaces as a
# session notification.  Use stderr so it appears in the user-visible
# session log even when stdout is captured.
cat <<'MSG' >&2

──────────────────────────────────────────────────────────────────────────
 qship plugin installed — one-time setup required
──────────────────────────────────────────────────────────────────────────

  qship ships a 21-skill pipeline (qship, qshipmaster, qcheck, qbug,
  qbcheck, qe2etest, qmanualt, …) that needs to know about YOUR codebase before
  they can run — repo paths, Jira project key, GitHub host, default
  branch, lint/test commands, etc.

  To configure, run inside Claude Code:

      /qship:configure

  This walks through a short questionnaire (7 rounds, each with a sensible
  default) plus a per-repo loop, then renders the full skill catalog into
  ~/.claude/skills/.  Re-runnable any time you want to change a value.

  Prefer the terminal?  Equivalent:

      bash $CLAUDE_PLUGIN_ROOT/setup.sh

  HEADS UP: qship delegates some review/bug-hunt steps to 5 external plugins
  (superpowers, feature-dev, code-review, code-simplifier, pr-review-toolkit).
  The configurator checks for them; install any it reports missing, or your
  first /qship run will fail mid-pipeline.  Verify any time with:

      bash $CLAUDE_PLUGIN_ROOT/setup.sh --check

──────────────────────────────────────────────────────────────────────────
MSG

# Exit 0 — soft prompt, never block.
exit 0
