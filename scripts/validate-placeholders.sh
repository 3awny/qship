#!/usr/bin/env bash
# validate-placeholders.sh — scan every templated file in templates/ for
# {{NAME}} tokens, then confirm each NAME is defined in config.example.json.
#
# Catches the regression: contributor adds {{NEW_PLACEHOLDER}} to a skill
# body but forgets to wire it into setup.sh / config.example.json.  Without
# this, the placeholder ships unfilled and skills look broken to users.
#
# Reports:
#   - Used in templates but UNDEFINED in config.example.json  → ERROR
#   - Defined in config.example.json but UNUSED in templates  → WARNING (dead config)
#
# Exit codes: 0 = all defined, 1 = undefined placeholders found, 2 = config missing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES_ROOT="$REPO_ROOT/templates"
CONFIG_EXAMPLE="$REPO_ROOT/config.example.json"

[[ -d "$TEMPLATES_ROOT" ]]  || { echo "FATAL: $TEMPLATES_ROOT missing"; exit 2; }
[[ -f "$CONFIG_EXAMPLE" ]]  || { echo "FATAL: $CONFIG_EXAMPLE missing"; exit 2; }
command -v jq >/dev/null    || { echo "FATAL: jq required"; exit 2; }

# 1. Collect every {{TOKEN}} found in templates/.  Allow upper/digit/underscore
# inside the braces.  Strip the braces via tr to avoid BSD-sed metachar issues.
USED="$(grep -rEoh '\{\{[A-Z][A-Z0-9_]*\}\}' "$TEMPLATES_ROOT" 2>/dev/null \
        | tr -d '{}' \
        | sort -u)"

# 2. Collect every leaf-scalar key from config.example.json (UPPERCASED).
# Skip metadata keys starting with _ or $.
# Skip the repos array — its per-entry keys are runtime metadata read via jq
# at install/runtime, not flat template placeholders.
DEFINED_CONFIG="$(jq -r '
  paths(type != "object" and type != "array") as $p
  | select($p[0] != "repos")
  | $p[-1]
  | select(test("^[_$]") | not)
  | ascii_upcase
' "$CONFIG_EXAMPLE" | sort -u)"

# Derived placeholders set by setup.sh (not in config.example.json directly).
# PRIMARY_REPO_NAME: resolved from repos[].is_primary at install time.
# REPO_COUNT:       length of repos[].
DERIVED="PRIMARY_REPO_NAME
REPO_COUNT"

DEFINED="$(printf '%s\n%s\n' "$DEFINED_CONFIG" "$DERIVED" | sort -u)"

# 3. Diff.
UNDEFINED="$(comm -23 <(echo "$USED") <(echo "$DEFINED"))"
UNUSED="$(comm -13 <(echo "$USED") <(echo "$DEFINED"))"

if [[ -n "$UNDEFINED" ]]; then
    echo "❌ Placeholders used in templates/ but NOT defined in config.example.json:"
    echo "$UNDEFINED" | awk '{print "    {{" $0 "}}"}'
    echo
fi

if [[ -n "$UNUSED" ]]; then
    echo "⚠️  Keys defined in config.example.json but UNUSED in templates/ (dead config?):"
    echo "$UNUSED" | awk '{print "    " $0}'
    echo
fi

count_nonempty() { local n; n="$(echo "$1" | grep -c . 2>/dev/null)" || n=0; echo "${n:-0}"; }
USED_COUNT="$(count_nonempty "$USED")"
DEFINED_COUNT="$(count_nonempty "$DEFINED")"
UNDEFINED_COUNT="$(count_nonempty "$UNDEFINED")"

echo "---"
echo "Scanned $USED_COUNT distinct {{PLACEHOLDERS}} in $TEMPLATES_ROOT"
echo "Against $DEFINED_COUNT leaf keys in $CONFIG_EXAMPLE"
echo
echo "Note: keys defined in config but unused in templates may still be intentional —"
echo "they're consumed by setup.sh directly (feature flags, lint/test commands, etc.)."
echo "Review the UNUSED list above and prune only if genuinely dead."

if [[ "$UNDEFINED_COUNT" -gt 0 ]]; then
    echo
    echo "❌ $UNDEFINED_COUNT placeholder(s) undefined — add them to config.example.json + setup.sh + skills/configure/SKILL.md"
    exit 1
fi

echo "✅ Every {{PLACEHOLDER}} used in templates is defined in config.example.json"
exit 0
