#!/bin/bash
# qshipmaster-state.sh — atomic read/write helpers for {{STATE_ROOT}}/epic-<EPIC>/state.json
#
# Sourced by the other qshipmaster hooks. Never invoked directly. Provides:
#   state_path <EPIC>                        → echoes path to state.json
#   state_init <EPIC> <summary> <branch> <repos_json> <waves_json> <base>
#   state_get <EPIC> <jq_filter>             → echoes value at filter
#   state_set <EPIC> <jq_filter> <value>     → atomic update via tmpfile + mv
#   state_status <EPIC>                       → human-readable status diagnosis
#
# All writes use the temp-file + atomic rename pattern so a crash mid-write
# leaves the prior state intact.

set -eo pipefail

EPIC_ROOT="${EPIC_ROOT:-{{STATE_ROOT}}-epic}"

state_path() {
    local epic="$1"
    echo "${EPIC_ROOT}-${epic}/state.json"
}

state_dir() {
    local epic="$1"
    echo "${EPIC_ROOT}-${epic}"
}

state_init() {
    local epic="$1" summary="$2" branch="$3" repos_json="$4" waves_json="$5" base="$6"
    local dir
    dir=$(state_dir "$epic")
    mkdir -p "$dir/logs"
    local sp
    sp=$(state_path "$epic")

    if [ -s "$sp" ]; then
        echo "[state] state.json already exists at $sp — skipping init" >&2
        return 0
    fi

    jq -n \
        --arg epic "$epic" \
        --arg summary "$summary" \
        --arg branch "$branch" \
        --argjson repos "$repos_json" \
        --argjson waves "$waves_json" \
        --arg base "$base" \
        '{epic: $epic,
          epic_summary: $summary,
          epic_branch: $branch,
          repos: $repos,
          base_branch: $base,
          waves: $waves,
          pr_url_per_repo: {},
          status: "in_flight",
          created_at: (now | todateiso8601)}' > "$sp.tmp"
    mv "$sp.tmp" "$sp"
}

state_get() {
    local epic="$1" filter="$2"
    local sp
    sp=$(state_path "$epic")
    if [ ! -s "$sp" ]; then
        echo "null"
        return 0
    fi
    jq -r "$filter" < "$sp"
}

state_set() {
    local epic="$1" filter="$2" value="$3"
    local sp
    sp=$(state_path "$epic")
    if [ ! -s "$sp" ]; then
        echo "[state] cannot set on missing state.json: $sp" >&2
        return 1
    fi
    # Use --argjson when value is valid JSON; fall back to --arg.
    if echo "$value" | jq -e . >/dev/null 2>&1; then
        jq --argjson v "$value" "$filter = \$v" < "$sp" > "$sp.tmp"
    else
        jq --arg v "$value" "$filter = \$v" < "$sp" > "$sp.tmp"
    fi
    mv "$sp.tmp" "$sp"
}

state_status() {
    local epic="$1"
    local sp
    sp=$(state_path "$epic")
    if [ ! -s "$sp" ]; then
        echo "MISSING"
        return 0
    fi
    jq -r '
      "status: " + .status,
      "epic_branch: " + .epic_branch,
      "repos: " + (.repos | join(", ")),
      "waves:",
      (.waves[] | "  wave " + (.n | tostring) + " [" + .status + "]: " + (.tickets | join(", ")))
    ' < "$sp"
}

# Allow direct invocation for debugging: `qshipmaster-state.sh status {{JIRA_PROJECT_KEY}}-EX01`
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        path)   state_path "$@" ;;
        get)    state_get  "$@" ;;
        set)    state_set  "$@" ;;
        status) state_status "$@" ;;
        *) echo "Usage: $0 {path|get|set|status} <EPIC> [args]" >&2; exit 2 ;;
    esac
fi
