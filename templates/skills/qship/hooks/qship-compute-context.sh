#!/bin/bash
# qship-compute-context.sh — classify a ticket's diff to decide what E2E is required.
#
# Usage: qship-compute-context.sh <TICKET_ID>
#
# Inspects each repo worktree under {{STATE_ROOT}}/worktrees/<TICKET>/ (or main
# monorepo if running in main checkout), computes a diff against the merge-base
# with develop, and writes pipeline-context.json. Subsequent hooks read it to
# decide whether API evidence, UI evidence, or both must appear in
# phase3-evidence.md.
#
# Globs are derived from the {{COMPANY_SLUG}} monorepo layout:
#   API source:  */{{CODEBASE_PATH_PREFIX}}/**/api/**/*.py  (NOT tests/api/)
#   UI source:   */{{CODEBASE_PATH_PREFIX}}/**/ui/**/*  AND  */components/react/**  AND  *.tsx|*.jsx
#   {{PRIMARY_REPO_NAME}} has no UI and no runtime HTTP API (worker/connector).
#
# Output schema ({{STATE_ROOT}}/worktrees/<TICKET>/pipeline-context.json):
# {
#   "ticket": "{{JIRA_PROJECT_KEY}}-42",
#   "computed_at": "2026-04-21T12:34:56Z",
#   "repos_inspected": ["{{PRIMARY_REPO_NAME}}", "{{PRIMARY_REPO_NAME}}"],
#   "api_changed": true,
#   "ui_changed": false,
#   "ui_consumer_changed": true,
#   "changed_endpoints": ["/api/v1/organizations/{id}/aliases"],
#   "ui_consumer_refs": [
#     "{{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react/src/components/Records.tsx"
#   ],
#   "api_files_changed": ["{{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/api/v1/records.py"],
#   "ui_files_changed": []
# }

set -eo pipefail

TICKET="${1:-}"
if [ -z "$TICKET" ] || ! [[ "$TICKET" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "Usage: qship-compute-context.sh <TICKET_ID>" >&2
  echo "  TICKET_ID must match [A-Z]+-[0-9]+ (e.g. {{JIRA_PROJECT_KEY}}-42)" >&2
  exit 2
fi

WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
MONOREPO_ROOT="${{{COMPANY_SLUG_UPPER}}_MONOREPO_ROOT:-{{CODEBASE_ROOT}}}"
BASE_BRANCH="${QSHIP_BASE_BRANCH:-develop}"

TICKET_DIR="$WORKTREE_ROOT/$TICKET"
mkdir -p "$TICKET_DIR"
OUT="$TICKET_DIR/pipeline-context.json"

REPOS=( $(jq -r ".[].name" "$SKILLS_ROOT/qship/repos.json") )

# A file qualifies as an API source file when it is under any {{CODEBASE_PATH_PREFIX}}/**/api/** path
# but NOT inside tests/ or archive/. Dash callbacks inside ui/ that happen to
# hit HTTP endpoints are UI, not API.
is_api_file() {
  local f="$1"
  case "$f" in
    */tests/*|*/archive/*) return 1 ;;
    */{{CODEBASE_PATH_PREFIX}}/*/api/*.py|*/{{CODEBASE_PATH_PREFIX}}/*/api/*/*.py|*/{{CODEBASE_PATH_PREFIX}}/*/api/*/*/*.py|*/{{CODEBASE_PATH_PREFIX}}/*/api/*/*/*/*.py) return 0 ;;
    *) return 1 ;;
  esac
}

# A file is UI when it's under ui/ or components/react/ or has a frontend
# extension. Dash pages in Python land under ui/ too.
is_ui_file() {
  local f="$1"
  case "$f" in
    */tests/*) return 1 ;;
    */ui/*|*/components/react/*|*/dash_pages/*) return 0 ;;
    *.tsx|*.jsx|*.ts|*.js) return 0 ;;
    *) return 1 ;;
  esac
}

# Extract endpoint path strings from a Python API file diff (router decorators).
# Examples we match: @router.get("/organizations/{id}"), @app.post("/foo")
extract_endpoint_paths() {
  local file="$1"
  # Print routes as relative paths; we do not reconstruct full prefixes here.
  grep -hoE '@(router|app|api)\.(get|post|put|patch|delete)\("[^"]+"' "$file" 2>/dev/null \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | sort -u
}

# Search the UI source trees for a literal endpoint path. Returns first few
# matches as "<repo>/<path>:<linenum>".
find_ui_refs() {
  local endpoint="$1"
  # Strip trailing slash and path params for a broader match.
  local prefix
  prefix=$(echo "$endpoint" | sed -E 's|\{[^}]+\}|[^/"]+|g; s|/+$||')
  # Use only the first path segment beyond /api/ as the search needle — precise
  # enough, tolerant to client-side path construction.
  local needle
  needle=$(echo "$endpoint" | sed -E 's|^/?api/v?[0-9]*/||; s|/.*$||')
  [ -z "$needle" ] && return 0

  for repo in "${REPOS[@]}"; do
    local uidir="$MONOREPO_ROOT/$repo"
    [ -d "$uidir" ] || continue
    # Search UI directories only; ignore tests, build artefacts, lockfiles.
    find "$uidir" -type f \
      \( -path '*/ui/*' -o -path '*/components/react/*' -o -path '*/dash_pages/*' \) \
      ! -path '*/node_modules/*' ! -path '*/dist/*' ! -path '*/build/*' ! -path '*/venv/*' \
      -name '*.tsx' -o -name '*.jsx' -o -name '*.ts' -o -name '*.js' -o -name '*.py' 2>/dev/null \
    | xargs grep -l -F "$needle" 2>/dev/null \
    | head -5 \
    | sed "s|^$MONOREPO_ROOT/||"
  done | sort -u
}

# Resolve where to compute the diff for a given repo: worktree first, fall
# back to main monorepo if no worktree exists.
repo_source_dir() {
  local repo="$1"
  local wt="$TICKET_DIR/$repo"
  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    echo "$wt"
  elif [ -d "$MONOREPO_ROOT/$repo/.git" ]; then
    echo "$MONOREPO_ROOT/$repo"
  fi
}

api_files_changed=()
ui_files_changed=()
changed_endpoints=()
ui_consumer_refs=()
repos_inspected=()

for repo in "${REPOS[@]}"; do
  src=$(repo_source_dir "$repo")
  [ -z "$src" ] && continue

  # Figure out the merge-base vs develop. If develop doesn't exist locally,
  # fall back to the current HEAD vs its upstream (no diff — empty list).
  base_sha=""
  if git -C "$src" rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    base_sha=$(git -C "$src" merge-base HEAD "$BASE_BRANCH" 2>/dev/null || true)
  fi

  if [ -z "$base_sha" ]; then
    # Inspected but nothing to diff against — record and move on.
    repos_inspected+=("$repo")
    continue
  fi

  repos_inspected+=("$repo")

  # List changed files relative to the repo root.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    prefixed="$repo/$f"
    if is_api_file "$prefixed"; then
      api_files_changed+=("$prefixed")
      # Extract endpoint paths from the current content of the changed file.
      while IFS= read -r ep; do
        [ -n "$ep" ] && changed_endpoints+=("$ep")
      done < <(extract_endpoint_paths "$src/$f")
    fi
    if is_ui_file "$prefixed"; then
      ui_files_changed+=("$prefixed")
    fi
  done < <(git -C "$src" diff --name-only "$base_sha"..HEAD 2>/dev/null)
done

# De-dup endpoints.
if [ "${#changed_endpoints[@]}" -gt 0 ]; then
  mapfile_compat() { local arr=(); while IFS= read -r l; do arr+=("$l"); done; printf '%s\n' "${arr[@]}"; }
  IFS=$'\n' changed_endpoints=($(printf '%s\n' "${changed_endpoints[@]}" | sort -u))
fi

# For each changed endpoint, find UI consumer references.
for ep in "${changed_endpoints[@]}"; do
  while IFS= read -r ref; do
    [ -n "$ref" ] && ui_consumer_refs+=("$ref")
  done < <(find_ui_refs "$ep")
done

# De-dup refs.
if [ "${#ui_consumer_refs[@]}" -gt 0 ]; then
  IFS=$'\n' ui_consumer_refs=($(printf '%s\n' "${ui_consumer_refs[@]}" | sort -u))
fi

# Booleans.
api_changed=false
ui_changed=false
ui_consumer_changed=false
[ "${#api_files_changed[@]}" -gt 0 ] && api_changed=true
[ "${#ui_files_changed[@]}" -gt 0 ] && ui_changed=true
[ "${#ui_consumer_refs[@]}" -gt 0 ] && ui_consumer_changed=true

# Build JSON via jq so strings are escaped correctly.
jq -n \
  --arg ticket "$TICKET" \
  --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson api_changed "$api_changed" \
  --argjson ui_changed "$ui_changed" \
  --argjson ui_consumer_changed "$ui_consumer_changed" \
  --argjson api_files "$(printf '%s\n' "${api_files_changed[@]:-}" | jq -R . | jq -s .)" \
  --argjson ui_files "$(printf '%s\n' "${ui_files_changed[@]:-}" | jq -R . | jq -s .)" \
  --argjson endpoints "$(printf '%s\n' "${changed_endpoints[@]:-}" | jq -R . | jq -s .)" \
  --argjson ui_refs "$(printf '%s\n' "${ui_consumer_refs[@]:-}" | jq -R . | jq -s .)" \
  --argjson repos "$(printf '%s\n' "${repos_inspected[@]:-}" | jq -R . | jq -s .)" \
  '{
    ticket: $ticket,
    computed_at: $ts,
    repos_inspected: ($repos | map(select(length > 0))),
    api_changed: $api_changed,
    ui_changed: $ui_changed,
    ui_consumer_changed: $ui_consumer_changed,
    changed_endpoints: ($endpoints | map(select(length > 0))),
    ui_consumer_refs: ($ui_refs | map(select(length > 0))),
    api_files_changed: ($api_files | map(select(length > 0))),
    ui_files_changed: ($ui_files | map(select(length > 0)))
  }' > "$OUT"

echo "wrote $OUT"
jq . "$OUT"
