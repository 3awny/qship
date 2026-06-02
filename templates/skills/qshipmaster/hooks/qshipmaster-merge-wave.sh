#!/bin/bash
# qshipmaster-merge-wave.sh — merge a wave's ticket branches into the
# consolidated epic branch. Per repo. Additive conflict policy.
#
# Usage: qshipmaster-merge-wave.sh <EPIC> <wave_n>
#
# Pre-conditions:
#   - state.json exists, wave_n is in waves[], all tickets in wave passed qshipcheck.
#   - Each ticket branch <TICKET>-... exists in the repo.
#
# Post-conditions:
#   - <epic_branch> tip contains all wave_n ticket branches merged.
#   - state.json.waves[wave_n-1].status = "merged" (Phase 2 still pending).

set -eo pipefail

EPIC="${1:-}"
WAVE_N="${2:-}"
if [ -z "$EPIC" ] || [ -z "$WAVE_N" ]; then
    echo "Usage: $0 <EPIC-ID> <wave_n>" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qshipmaster-state.sh
source "$SCRIPT_DIR/qshipmaster-state.sh"

EPIC_DIR=$(state_dir "$EPIC")
LOG="$EPIC_DIR/logs/wave-${WAVE_N}-merge.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

REPO_ROOT="${REPO_ROOT:-{{CODEBASE_ROOT}}}"

EPIC_BRANCH=$(state_get "$EPIC" '.epic_branch')
BASE_BRANCH=$(state_get "$EPIC" '.base_branch')
WAVE_TICKETS=(); while IFS= read -r line; do WAVE_TICKETS+=("$line"); done < <(state_get "$EPIC" ".waves[$((WAVE_N - 1))].tickets[]")
REPOS=(); while IFS= read -r line; do REPOS+=("$line"); done < <(state_get "$EPIC" '.repos[]')

if [ "${#WAVE_TICKETS[@]}" -eq 0 ]; then
    echo "[$(ts)] wave $WAVE_N has no tickets — nothing to merge" | tee -a "$LOG"
    exit 0
fi

# Resolve each ticket key → branch name. Workers in EPIC_MODE follow the
# convention "<TICKET>-<short-slug>" but the slug varies — discover by listing
# branches matching the prefix in the repo.
resolve_branch() {
    local repo_dir="$1" ticket="$2"
    cd "$repo_dir"
    local b
    b=$(git for-each-ref --format='%(refname:short)' "refs/heads/${ticket}-*" 2>/dev/null | head -1)
    if [ -z "$b" ]; then
        b=$(git for-each-ref --format='%(refname:short)' "refs/heads/${ticket}" 2>/dev/null | head -1)
    fi
    echo "$b"
}

merge_one_repo() {
    local repo="$1"
    local repo_dir="$REPO_ROOT/$repo"

    if [ ! -d "$repo_dir/.git" ]; then
        echo "[$(ts)] [$repo] not a git repo at $repo_dir — skipping" | tee -a "$LOG"
        return 0
    fi

    cd "$repo_dir"
    git fetch --all --prune 2>&1 | tee -a "$LOG" >/dev/null

    # Ensure epic branch exists locally; for Wave 1, base it on BASE_BRANCH.
    if ! git rev-parse --verify "$EPIC_BRANCH" >/dev/null 2>&1; then
        echo "[$(ts)] [$repo] creating $EPIC_BRANCH from $BASE_BRANCH" | tee -a "$LOG"
        git checkout -b "$EPIC_BRANCH" "$BASE_BRANCH"
    else
        git checkout "$EPIC_BRANCH"
    fi

    local merged_count=0
    for ticket in "${WAVE_TICKETS[@]}"; do
        local branch
        branch=$(resolve_branch "$repo_dir" "$ticket")
        if [ -z "$branch" ]; then
            echo "[$(ts)] [$repo] no local branch for $ticket — skipping (likely belongs to another repo)" | tee -a "$LOG"
            continue
        fi

        # Already merged? Skip.
        if git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
            echo "[$(ts)] [$repo] $branch already in $EPIC_BRANCH — skipping" | tee -a "$LOG"
            merged_count=$((merged_count + 1))
            continue
        fi

        echo "[$(ts)] [$repo] merging $branch into $EPIC_BRANCH" | tee -a "$LOG"
        if git merge --no-ff "$branch" -m "merge: $branch into $EPIC_BRANCH"; then
            merged_count=$((merged_count + 1))
            continue
        fi

        # Conflict path. Inspect unmerged paths.
        local unmerged
        unmerged=$(git diff --name-only --diff-filter=U)
        echo "[$(ts)] [$repo] CONFLICT merging $branch. Unmerged paths:" | tee -a "$LOG"
        echo "$unmerged" | tee -a "$LOG"

        # Additive merge attempt for known files (qship SKILL.md §12.2).
        local additive_files=("index.js" "component_wrapper.py" "app.py" "__init__.py")
        local resolved_all=1
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            local base
            base=$(basename "$path")
            local matched=0
            for af in "${additive_files[@]}"; do
                if [ "$base" = "$af" ]; then matched=1; break; fi
            done
            if [ "$matched" -eq 1 ]; then
                # Take both sides — naive approach: union the file lines from both
                # parents. Works for export lists / registrations / __init__ files.
                git checkout --theirs -- "$path" 2>/dev/null || true
                git checkout --ours -- "$path" 2>/dev/null || true
                # Use git's union merge driver explicitly:
                git merge-file -p --union \
                    <(git show :2:"$path" 2>/dev/null || cat "$path") \
                    <(git show :1:"$path" 2>/dev/null || cat "$path") \
                    <(git show :3:"$path" 2>/dev/null || cat "$path") \
                    > "$path.union" 2>/dev/null || resolved_all=0
                if [ -s "$path.union" ]; then
                    mv "$path.union" "$path"
                    git add "$path"
                    echo "[$(ts)] [$repo] additive-resolved $path" | tee -a "$LOG"
                else
                    rm -f "$path.union"
                    resolved_all=0
                fi
            else
                resolved_all=0
            fi
        done <<< "$unmerged"

        if [ "$resolved_all" -eq 1 ] && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
            git commit --no-edit
            merged_count=$((merged_count + 1))
            continue
        fi

        # Non-additive conflict — dispatch a claude --print subprocess to
        # resolve based on understanding of both tickets' context. Falls back
        # to the original abort+marker behaviour only if auto-resolve fails.
        # (Per user request after {{JIRA_PROJECT_KEY}}-EX05/{{JIRA_PROJECT_KEY}}-679 conflict on
        # record_template.py: both branches added independent new
        # methods at the same location — sonnet handled "keep both" trivially.)
        echo "[$(ts)] [$repo] non-additive conflict in $branch — dispatching auto-resolver (sonnet)" | tee -a "$LOG"

        local resolver_log="$EPIC_DIR/logs/wave-${WAVE_N}-${repo}-conflict-resolve.log"
        local ticket_id="${branch%%-*}"
        local resolver_prompt
        resolver_prompt="You are resolving a git merge conflict in an autonomous qshipmaster epic pipeline. There is NO human to ask — pick the most defensible resolution and commit.

Repo: $repo (cwd: $repo_dir)
Epic: $EPIC ($EPIC_BRANCH)
Wave: $WAVE_N
Merging ticket branch: $branch (ticket: $ticket_id)
Conflicted files:
$unmerged

For each conflicted file:
1. Read the file with conflict markers (<<<<<<<, =======, >>>>>>>).
2. Inspect BOTH sides: 'git show :2:<path>' is HEAD (the epic branch with prior waves), 'git show :3:<path>' is the incoming ticket branch.
3. Look up both tickets' purposes: for HEAD-side use 'git log --oneline -10 HEAD -- <path>'; for incoming-side use 'git log --oneline -10 $branch -- <path>'.
4. Resolution policy (in priority order):
   a. If both sides ADD independent new functions/methods/classes at the same location — KEEP BOTH (concatenate). This is the most common case.
   b. If both sides MODIFY the same function/method differently — prefer the side whose ticket's acceptance criteria most directly involve that symbol; preserve callers from the other side.
   c. If both sides ADD overlapping imports — union them, dedupe.
   d. If both sides ADD overlapping enum/dict values — union, error if same key with different values.
   e. Last resort: prefer HEAD (epic branch, has prior-wave context) but graft the incoming side's NEW behaviours next to it.
5. After resolution: remove ALL conflict markers, run 'python3 -c \"import ast; ast.parse(open(\\\"<path>\\\").read())\"' on .py files to verify syntax.
6. 'git add' each resolved file.
7. When all resolved: 'git commit --no-edit' to complete the merge.

NON-NEGOTIABLE:
- DO NOT 'git merge --abort'. The orchestrator depends on the merge completing.
- DO NOT write a marker file or escalate — you ARE the autonomy mechanism.
- DO NOT introduce new logic; only union/select existing code from the two sides.
- DO NOT change line endings, indentation, or formatting of unrelated code.
- If you genuinely cannot resolve (e.g. semantic contradiction between branches), DOCUMENT in {{STATE_ROOT}}/epic-$EPIC/wave-${WAVE_N}-conflict-unresolvable.md and exit non-zero — that's the only escape hatch."

        local timeout_bin
        timeout_bin="$(command -v timeout || command -v gtimeout || true)"
        local rc=1
        if [ -n "$timeout_bin" ]; then
            "$timeout_bin" --kill-after=30s 1200 \
                claude --print \
                    --dangerously-skip-permissions \
                    --allowedTools "Bash,Read,Edit,Write,Glob,Grep" \
                    --model sonnet \
                    --append-system-prompt "$resolver_prompt" \
                    "Resolve the conflicts now. Start by listing 'git diff --name-only --diff-filter=U'." \
                    > "$resolver_log" 2>&1
            rc=$?
        else
            claude --print \
                --dangerously-skip-permissions \
                --allowedTools "Bash,Read,Edit,Write,Glob,Grep" \
                --model sonnet \
                --append-system-prompt "$resolver_prompt" \
                "Resolve the conflicts now. Start by listing 'git diff --name-only --diff-filter=U'." \
                > "$resolver_log" 2>&1
            rc=$?
        fi

        # Verify: no markers left + index clean + merge committed.
        local remaining_unmerged
        remaining_unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
        local has_markers=0
        if [ -n "$remaining_unmerged" ] || git -c core.quotepath=false grep -l '^<<<<<<< \|^=======$\|^>>>>>>> ' -- . 2>/dev/null | grep -q .; then
            has_markers=1
        fi
        # Has the merge been finalised? merge_msg vanishes once commit lands.
        local merge_in_progress=0
        [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] && merge_in_progress=1

        if [ "$rc" -eq 0 ] && [ "$has_markers" -eq 0 ] && [ "$merge_in_progress" -eq 0 ]; then
            echo "[$(ts)] [$repo] auto-resolver succeeded — merge committed" | tee -a "$LOG"
            merged_count=$((merged_count + 1))
            continue
        fi

        # Auto-resolver failed. Fall back to the original marker-and-abort
        # behaviour so a human can inspect.
        echo "[$(ts)] [$repo] auto-resolver FAILED (rc=$rc, markers=$has_markers, merge_in_progress=$merge_in_progress) — see $resolver_log; writing marker for SendMessage flow" | tee -a "$LOG"
        cat > "$EPIC_DIR/wave-${WAVE_N}-conflict.json" <<EOF
{
  "wave": $WAVE_N,
  "repo": "$repo",
  "ticket_branch": "$branch",
  "epic_branch": "$EPIC_BRANCH",
  "unmerged_paths": $(echo "$unmerged" | jq -R . | jq -s .),
  "repo_dir": "$repo_dir",
  "resolver_log": "$resolver_log",
  "resolver_rc": $rc
}
EOF
        git merge --abort 2>/dev/null || true
        return 5
    done

    echo "[$(ts)] [$repo] merged $merged_count branches into $EPIC_BRANCH" | tee -a "$LOG"
    return 0
}

for repo in "${REPOS[@]}"; do
    if ! merge_one_repo "$repo"; then
        echo "[$(ts)] HALT: merge failed for $repo. See $EPIC_DIR/wave-${WAVE_N}-conflict.json" | tee -a "$LOG"
        exit 5
    fi
done

# Mark wave as merged (Phase 2 still pending).
state_set "$EPIC" ".waves[$((WAVE_N - 1))].status" "merged"
state_set "$EPIC" ".waves[$((WAVE_N - 1))].merged_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[$(ts)] wave $WAVE_N merge complete" | tee -a "$LOG"
