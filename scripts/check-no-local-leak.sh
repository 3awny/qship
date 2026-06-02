#!/usr/bin/env bash
# check-no-local-leak.sh — CONTRIBUTOR safety net (needs no maintainer files).
#
# Confirms that none of YOUR onboarded values (from answers/last-run.json) have
# been accidentally typed into a tracked/publishable file. It uses your own
# config as the deny-list — the values you actually changed from the generic
# config.example.json — so it catches "I pasted my real repo name / company /
# home path into a skill body instead of the {{PLACEHOLDER}}".
#
# This is complementary to scripts/lint-forbidden.sh (which is maintainer-only
# and targets the ORIGINAL author's data). This one targets YOUR data, locally.
#
# No-ops cleanly if you never onboarded (no answers/last-run.json).
# Exit 0 = clean, 1 = a local value leaked into a tracked file, 2 = setup error.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || { echo "cannot cd to repo root"; exit 2; }
ANSWERS="$REPO_ROOT/answers/last-run.json"
EXAMPLE="$REPO_ROOT/config.example.json"

if [[ ! -f "$ANSWERS" ]]; then
  echo "ℹ  No answers/last-run.json — you haven't onboarded, so there's nothing"
  echo "   personal to leak. (This check becomes meaningful after you run setup.sh.)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "jq required for this check"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git required for this check"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Every string scalar from your answers (recurses into repos[] objects too) and
# from the generic example — EXCLUDING metadata leaves whose key starts with `_`
# or `$` (e.g. `_generated_by: "setup.sh"`, `$schema`, `_comment`), which are
# tooling artefacts, not your data, and would cause false positives.
# Anything in your answers that ALSO appears in the example is an unchanged
# default — not distinctive — so it's subtracted from the deny-list below.
_scalars() {
  jq -r '
    paths(type=="string") as $p
    | ($p[-1]) as $leaf
    | select( ($leaf | type=="string" and (startswith("_") or startswith("$"))) | not )
    | getpath($p)
  ' "$1" 2>/dev/null | sort -u
}
_scalars "$ANSWERS"  > "$TMP/mine"
_scalars "$EXAMPLE"  > "$TMP/examples"

# Build the deny-list: your distinctive values only.
: > "$TMP/deny"
while IFS= read -r v; do
  [ -z "$v" ] && continue
  [ "${#v}" -lt 4 ] && continue                      # too short → substring noise
  case "$v" in
    true|false|null|develop|main|master|trunk|src|app|lib|localhost|\
    python|typescript|go|mixed|github.com|dev_db|app_admin|public|\
    your-org|your-repo|acme|PROJ|SERVICE_URL|CLOUD_URL|OAUTH_CLIENT_ID|OAUTH_CLIENT_SECRET)
      continue ;;
  esac
  grep -qxF -- "$v" "$TMP/examples" && continue       # unchanged from example → skip
  printf '%s\n' "$v" >> "$TMP/deny"
done < "$TMP/mine"

if [ ! -s "$TMP/deny" ]; then
  echo "✅ All your configured values still match the generic examples — nothing distinctive to leak."
  exit 0
fi

echo "Checking tracked files for ${0##*/}'s deny-list ($(wc -l < "$TMP/deny" | tr -d ' ') distinctive value(s) from your config)…"

# Scan only TRACKED files (git ls-files). Your config.json / answers/ are
# gitignored, so they're never in this list — exactly what we want.
hits=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if grep -nFf "$TMP/deny" -- "$f" >/dev/null 2>&1; then
    echo "❌ $f"
    grep -nFf "$TMP/deny" -- "$f" | head -5 | sed 's/^/     /'
    hits=$((hits + 1))
  fi
done < <(git ls-files)

echo
if [ "$hits" -gt 0 ]; then
  echo "❌ Found your onboarded value(s) in $hits tracked file(s)."
  echo "   Replace each literal with the matching {{PLACEHOLDER}} before committing."
  echo "   (Your config.json / answers/ are gitignored and safe — this is about a"
  echo "    real value typed into a template/doc/script body.)"
  exit 1
fi
echo "✅ None of your onboarded values appear in any tracked file. Safe to commit."
exit 0
