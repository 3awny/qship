#!/usr/bin/env bash
# uninstall.sh — remove qship's installed skills, restore settings.json from
# the most recent backup, and unlink codex symlinks.
set -euo pipefail

# Accept ONLY the JSON answers file. The legacy `.env` path used `source`, which
# executes the file (arbitrary code execution if the path/content is tampered) —
# removed.
ANSWERS="${1:-}"
if [[ -z "$ANSWERS" ]]; then
  CAND="$HOME/work/qship/answers/last-run.json"
  [[ -f "$CAND" ]] && ANSWERS="$CAND"
fi
[[ -f "$ANSWERS" ]] || { echo "Cannot find answers JSON: pass it as \$1 (e.g. answers/last-run.json)"; exit 2; }
case "$ANSWERS" in
  *.json) ;;
  *) echo "Only .json answers files are supported (got: $ANSWERS)"; exit 2 ;;
esac
command -v jq >/dev/null || { echo "jq required to read JSON answers"; exit 2; }
SKILLS_ROOT="$(jq -r '.codebase.skills_root // empty' "$ANSWERS")"
SKILLS_ROOT="${SKILLS_ROOT:-$HOME/.claude/skills}"

# Guard the destructive rm -rf below: skills_root must be an absolute path under
# $HOME, with no traversal, and never $HOME itself. Defends against a tampered
# answers file pointing skills_root at / or $HOME.
case "$SKILLS_ROOT" in
  "$HOME"/*) : ;;
  *) echo "❌ refusing to uninstall: skills_root ($SKILLS_ROOT) is not under \$HOME"; exit 1 ;;
esac
case "$SKILLS_ROOT" in
  *..*) echo "❌ refusing: skills_root contains '..'"; exit 1 ;;
esac

# The 21-skill pipeline qship installs (keep in sync with setup.sh).
SKILLS=(qship qshipmaster qshipcheck qshipphasecheck
  qplan qdirectory qclean qreuse
  qcheck qcheckt qcheckf qcomponent qbug qbcheck
  qmemory qe2etest qmanualt qspinuplocal qlocalclonedb
  qmigrationdevcheck qauthtrailingslash)

echo "==> Removing rendered skills under $SKILLS_ROOT"
for s in "${SKILLS[@]}"; do
  if [[ -d "$SKILLS_ROOT/$s" && ! -L "$SKILLS_ROOT/$s" ]]; then
    rm -rf "$SKILLS_ROOT/$s"
    echo "  removed $s"
  fi
done

echo "==> Removing Codex symlinks"
for s in "${SKILLS[@]}"; do
  [[ -L "$HOME/.codex/skills/$s" ]] && rm -f "$HOME/.codex/skills/$s"
done

settings="$HOME/.claude/settings.json"
echo "==> Restoring $settings from most recent backup"
latest_bak="$(ls -t "${settings}".bak.* 2>/dev/null | head -1 || true)"
if [[ -n "${latest_bak:-}" ]]; then
  cp "$latest_bak" "$settings"
  echo "  restored from $latest_bak"
else
  echo "  no backup found — leaving settings.json untouched"
fi

echo "==> Removing qship-worker agent"
rm -f "$HOME/.claude/agents/qship-worker.md"

echo "✅ uninstall complete"
