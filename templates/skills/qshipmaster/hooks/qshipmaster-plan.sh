#!/bin/bash
# qshipmaster-plan.sh — fetch Epic + children, build dependency-sorted wave
# plan, write {{STATE_ROOT}}/epic-<EPIC>/state.json.
#
# Idempotent: if state.json already exists with status != error, exits 0.
# Re-running with state.json deleted reconstructs the plan from Jira.
#
# Usage: qshipmaster-plan.sh {{JIRA_PROJECT_KEY}}-EX01
#
# Implementation: delegates the Atlassian MCP queries to a single
# `claude --print` invocation (defaults to opus[1m] at xhigh effort — see
# §"Model strategy" below).  This is the highest-leverage decision in the
# entire pipeline because a wrong wave plan cascades through 10-15 h of
# downstream work, so the planner gets the strongest available model +
# reasoning depth.  Override via QSHIP_PLAN_MODEL / QSHIP_PLAN_EFFORT.

set -eo pipefail

EPIC="${1:-}"
if [ -z "$EPIC" ]; then
    echo "Usage: $0 <EPIC-ID>" >&2
    exit 2
fi
if ! [[ "$EPIC" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "Invalid epic id: $EPIC" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qshipmaster-state.sh
source "$SCRIPT_DIR/qshipmaster-state.sh"

EPIC_DIR=$(state_dir "$EPIC")
SP=$(state_path "$EPIC")
mkdir -p "$EPIC_DIR/logs"
LOG="$EPIC_DIR/logs/plan.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Idempotence: skip if plan exists.
if [ -s "$SP" ]; then
    echo "[$(ts)] state.json exists at $SP — skipping plan fetch" | tee -a "$LOG"
    state_status "$EPIC"
    exit 0
fi

echo "[$(ts)] fetching epic $EPIC + children from Jira via ${QSHIP_PLAN_MODEL:-opus[1m]} ${QSHIP_PLAN_EFFORT:-xhigh} MCP..." | tee -a "$LOG"

FETCH_LOG="$EPIC_DIR/logs/jira-fetch.json"

# Wave planner: get the epic, get its children, parse Blocked-by deps,
# detect repo per child, output a single JSON blob we can parse.
#
# Model strategy (upgraded 2026-05): defaults to opus[1m] at xhigh effort.
# Rationale — this single call decides the ENTIRE epic's execution shape
# (wave topology, dependency-correct ordering, per-ticket repo routing).
# A wrong wave plan cascades through 10-15 hours of downstream work, so
# the planner is the highest-leverage decision in the pipeline and gets
# the strongest model + reasoning depth. 1M context lets the planner
# read every child description in full, including long Blocked-by
# rationales, without summarisation pressure.
#
# Override with QSHIP_PLAN_MODEL=haiku (cheap, fast, ~95% accuracy on
# simple epics with explicit Blocked-by:) and QSHIP_PLAN_EFFORT=low for
# rapid iteration during dev / dry-runs where you'll re-plan anyway.
claude --print --dangerously-skip-permissions \
    --allowedTools 'mcp__atlassian__jira_get_issue,mcp__atlassian__jira_search' \
    --model "${QSHIP_PLAN_MODEL:-opus[1m]}" \
    --effort "${QSHIP_PLAN_EFFORT:-xhigh}" \
    "Use the atlassian MCP for {{COMPANY_SLUG_LOWER}}.atlassian.net.

1. Call mcp__atlassian__jira_get_issue with issue_key=$EPIC and fields=\"summary,status,issuetype,description\". Record summary, issue_type.name, status.name. If issue_type.name != \"Epic\", emit only {\"error\": \"not_an_epic\", \"got\": \"<type>\"} and stop.

2. Call mcp__atlassian__jira_search with jql=\"parent = $EPIC ORDER BY created ASC\", fields=\"summary,status,description\", and limit=50. For each child:
   - capture key, summary, status.name
   - parse the description for repo hints. Look for headers like '## Repo:' or '## Affected Repo:' or any of the literal strings '{{PRIMARY_REPO_NAME}}', '{{PRIMARY_REPO_NAME}}', '{{PRIMARY_REPO_NAME}}', '{{PRIMARY_REPO_NAME}}'. Pick the most-mentioned. Default to '{{PRIMARY_REPO_NAME}}' if ambiguous.
   - parse the description for 'Blocked by:' lines. Capture the listed {{JIRA_PROJECT_KEY}}-NNN keys.

3. Output a SINGLE JSON object, no prose, no fences:
{
  \"epic\": \"$EPIC\",
  \"epic_summary\": \"<summary>\",
  \"epic_status\": \"<status>\",
  \"children\": [
    {\"key\": \"{{JIRA_PROJECT_KEY}}-NNN\", \"summary\": \"...\", \"status\": \"...\", \"repo\": \"{{COMPANY_SLUG}}-...\", \"blocked_by\": [\"{{JIRA_PROJECT_KEY}}-MMM\", ...]}
  ]
}" > "$FETCH_LOG" 2>&1 || true

# Extract the embedded JSON object (any model may wrap in prose / fences;
# parser stays defensive regardless of QSHIP_PLAN_MODEL).
python3 - "$FETCH_LOG" "$EPIC_DIR/jira.json" <<'PY'
import json, sys, re
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
# Strip ```json fences if present
m = re.search(r'```json\s*(\{.*?\})\s*```', text, re.S)
if m:
    obj = json.loads(m.group(1))
else:
    start = text.find('{')
    if start < 0:
        print("no JSON in fetch log", file=sys.stderr); sys.exit(1)
    depth = 0
    end = -1
    for i, c in enumerate(text[start:], start):
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                end = i + 1; break
    if end < 0:
        print("unbalanced JSON", file=sys.stderr); sys.exit(1)
    obj = json.loads(text[start:end])
with open(dst, 'w') as f:
    json.dump(obj, f, indent=2)
PY

if [ ! -s "$EPIC_DIR/jira.json" ]; then
    echo "[$(ts)] ERROR: failed to parse Jira fetch output. See $FETCH_LOG" | tee -a "$LOG"
    exit 1
fi

# Detect "not an epic" early-exit.
if jq -e '.error' < "$EPIC_DIR/jira.json" >/dev/null 2>&1; then
    err=$(jq -r '.error' < "$EPIC_DIR/jira.json")
    got=$(jq -r '.got // "unknown"' < "$EPIC_DIR/jira.json")
    echo "[$(ts)] HALT: $EPIC is not an Epic (got: $got). Use /qship instead." | tee -a "$LOG"
    exit 3
fi

EPIC_SUMMARY=$(jq -r '.epic_summary' < "$EPIC_DIR/jira.json")

# Topological sort the children into waves.
python3 - "$EPIC_DIR/jira.json" "$EPIC_DIR/waves.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
children = data.get("children", [])
keys = {c["key"] for c in children}
deps = {c["key"]: [b for b in c.get("blocked_by", []) if b in keys] for c in children}

# Kahn-style waves: each wave is the set of nodes whose deps are all already
# placed in earlier waves.
placed = set()
waves = []
remaining = dict(deps)
while remaining:
    wave_keys = sorted([k for k, ds in remaining.items() if all(d in placed for d in ds)])
    if not wave_keys:
        # Cycle detected — emit error and remaining.
        out = {"error": "cycle", "remaining": list(remaining.keys()), "waves": waves}
        json.dump(out, open(dst, "w"), indent=2)
        sys.exit(0)
    waves.append(wave_keys)
    placed.update(wave_keys)
    for k in wave_keys:
        remaining.pop(k, None)

# Distinct repos across all children. Canonicalize to on-disk monorepo dir names —
# tickets/TRDs commonly use the codename "{{PRIMARY_REPO_NAME}}" but the actual repo on disk
# is "{{PRIMARY_REPO_NAME}}" (see memory: feedback_frontend_is_{{PRIMARY_REPO_NAME}}).
# Without this remap, qshipmaster-merge-wave.sh and the wave batch-review dispatch
# both silently `cd` into a non-existent dir and skip — producing empty
# wave-N-phase23-evidence.md stubs (the {{JIRA_PROJECT_KEY}}-EX14 Phase 3 skip bug).
REPO_ALIAS = {
    "{{PRIMARY_REPO_NAME}}": "{{PRIMARY_REPO_NAME}}",
}
repos = sorted({REPO_ALIAS.get(c["repo"], c["repo"]) for c in children if c.get("repo")})

result = {
    "waves": [{"n": i + 1, "tickets": w, "status": "pending"} for i, w in enumerate(waves)],
    "repos": repos,
}
json.dump(result, open(dst, "w"), indent=2)
PY

if jq -e '.error' < "$EPIC_DIR/waves.json" >/dev/null 2>&1; then
    err=$(jq -r '.error' < "$EPIC_DIR/waves.json")
    echo "[$(ts)] HALT: $err detected in dependency graph. See $EPIC_DIR/waves.json" | tee -a "$LOG"
    # Persist a partial state.json so re-runs see the diagnosis.
    waves_json=$(jq '.waves' < "$EPIC_DIR/waves.json")
    repos_json=$(jq '.repos // []' < "$EPIC_DIR/waves.json")
    slug=$(echo "$EPIC_SUMMARY" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/--*/-/g; s/^-//; s/-$//')
    epic_branch="${EPIC}-${slug}"
    state_init "$EPIC" "$EPIC_SUMMARY" "$epic_branch" "$repos_json" "$waves_json" "develop"
    state_set "$EPIC" '.status' 'error'
    state_set "$EPIC" '.error' "$err"
    exit 4
fi

# Slugify epic summary → epic_branch.
SLUG=$(echo "$EPIC_SUMMARY" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/--*/-/g; s/^-//; s/-$//')
EPIC_BRANCH="${EPIC}-${SLUG}"

WAVES_JSON=$(jq '.waves' < "$EPIC_DIR/waves.json")
REPOS_JSON=$(jq '.repos' < "$EPIC_DIR/waves.json")

state_init "$EPIC" "$EPIC_SUMMARY" "$EPIC_BRANCH" "$REPOS_JSON" "$WAVES_JSON" "develop"

echo "[$(ts)] plan written to $SP" | tee -a "$LOG"
state_status "$EPIC" | tee -a "$LOG"
