#!/usr/bin/env bash
# lint-forbidden.sh — fail the build if any rendered template still contains a
# real customer ID, real email, real provider product name, etc.
#
# Reads scripts/forbidden-strings.txt — each non-blank, non-#-prefixed line is
# an extended-regex pattern.  Greps every file under templates/ for hits.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The forbidden-pattern deny-list lives OUTSIDE the public repo (it is the
# cleartext deanonymisation key). Override its location via QSHIP_MAINTAINER_DIR.
MAINTAINER_DIR="${QSHIP_MAINTAINER_DIR:-$HOME/.qship-maintainer}"
FORBIDDEN_FILE="$MAINTAINER_DIR/forbidden-strings.txt"

# Scan EVERYTHING under the repo, not just templates/ — the 2026-05-27 audit
# found leaks in docs/ and other root-level files that the templates-only
# scope missed.
SCAN_ROOT="$REPO_ROOT"

# Exclude paths that ship with the repo but would self-match (the scrub
# source mentions every forbidden token by construction — those live in
# $MAINTAINER_DIR now, so this is just belt-and-suspenders) plus .git
# and anything else that isn't meant to be linted.
EXCLUDES=(
    --exclude-dir=.git
    --exclude-dir=node_modules
    --exclude-dir=answers
    --exclude=*.bak.*
    # Author / maintainer attribution files — intentional personal-name usage:
    --exclude-dir=.claude-plugin
    --exclude-dir=.github
)
# Files that legitimately mention the maintainer by name (for attribution,
# contact info, security-advisory routing).  Skipped per-file rather than
# per-dir so we don't widen the exclude scope further than needed.
ATTRIBUTION_FILES=(
    "$SCAN_ROOT/CONTRIBUTING.md"
    "$SCAN_ROOT/README.md"
    # SECURITY.md + CODE_OF_CONDUCT.md carry the maintainer's contact email by
    # design (same as CONTRIBUTING/README) — intentional attribution, not a leak.
    "$SCAN_ROOT/SECURITY.md"
    "$SCAN_ROOT/CODE_OF_CONDUCT.md"
)

[[ ! -f "$FORBIDDEN_FILE" ]] && { echo "FATAL: $FORBIDDEN_FILE missing (set QSHIP_MAINTAINER_DIR or place it at $FORBIDDEN_FILE)"; exit 2; }
[[ ! -d "$SCAN_ROOT" ]] && { echo "FATAL: $SCAN_ROOT missing"; exit 2; }

FAIL=0
TOTAL=0

while IFS= read -r pat; do
  [[ -z "${pat:-}" || "${pat:0:1}" == "#" ]] && continue
  TOTAL=$((TOTAL + 1))
  # -r recursive, -E extended regex, -I skip binaries, -n line numbers
  local_hits="$(grep -rEnI "${EXCLUDES[@]}" -- "$pat" "$SCAN_ROOT" 2>/dev/null || true)"
  # Strip out attribution files (CONTRIBUTING.md mentions maintainer by name).
  for af in "${ATTRIBUTION_FILES[@]}"; do
    local_hits="$(echo "$local_hits" | grep -v "^${af}:" || true)"
  done
  if [[ -n "$local_hits" ]]; then
    echo "❌ FORBIDDEN PATTERN HIT: $pat"
    echo "$local_hits" | head -10 | sed 's/^/    /'
    [[ "$(echo "$local_hits" | wc -l | tr -d ' ')" -gt 10 ]] && echo "    … (more)"
    echo
    FAIL=$((FAIL + 1))
  fi
done < "$FORBIDDEN_FILE"

echo "---"
echo "Scanned $TOTAL forbidden patterns across $SCAN_ROOT (entire repo, excluding .git/node_modules/answers/*.bak.*)"
if [[ $FAIL -gt 0 ]]; then
  echo "❌ $FAIL forbidden pattern(s) found — build is NOT publishable"
  echo "Add a pattern to forbidden-strings.txt (or genericize the offending"
  echo "occurrence in templates/) and re-run this check."
  exit 1
fi
echo "✅ No forbidden strings found — templates are clean"
