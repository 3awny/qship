#!/usr/bin/env bash
# qship-watchdog.sh — one-shot stall detector for an in-flight qship worker.
#
# Usage:
#   qship-watchdog.sh <TICKET>                # print health snapshot to stdout
#   qship-watchdog.sh <TICKET> --json         # machine-readable JSON
#   qship-watchdog.sh <TICKET> --strict       # exit non-zero if stall detected
#
# Stall heuristic (any one triggers STALL):
#   1. No file modified under the worktree in the last $STALL_FILE_MIN minutes
#      (default 12). Excludes .git/, __pycache__, venv/, node_modules.
#   2. No new git commit on the branch in the last $STALL_COMMIT_MIN minutes
#      (default 25).
#   3. A background child process owned by the user has been alive >
#      $STALL_BG_MIN minutes with 0% recent CPU (default 30) AND its name
#      matches the dispatch-planner / codex / xhigh / claude-p patterns.
#
# This script is read-only — it will NEVER touch the worktree, kill processes,
# or message the worker. It just reports. The orchestrator decides what to do
# (SendMessage, KillShell, redispatch).
#
# Designed to be invoked every 5 min while a Phase 1/2/3/4 worker is in
# background. The cheapest periodic invocation is `ScheduleWakeup` (from
# /loop dynamic mode) or `/loop 5m bash ~/.claude/skills/qship/hooks/qship-watchdog.sh
# <TICKET>` (from a standalone session). For the in-session orchestrator, just
# call this as a Bash tool every time you check on the worker.

set -u
TICKET="${1:-}"
MODE="${2:-text}"
WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"

STALL_FILE_MIN="${STALL_FILE_MIN:-12}"
STALL_COMMIT_MIN="${STALL_COMMIT_MIN:-25}"
STALL_BG_MIN="${STALL_BG_MIN:-30}"

if [ -z "$TICKET" ]; then
  echo "Usage: qship-watchdog.sh <TICKET> [--json|--strict]" >&2
  exit 2
fi

WT="$WORKTREE_ROOT/$TICKET"
if [ ! -d "$WT" ]; then
  echo "❌ no worktree at $WT" >&2
  exit 3
fi

NOW=$(date +%s)
STALL=0
REASONS=()

# 1. Newest file under the worktree (excluding noise)
# macOS BSD find doesn't support -printf; pipe to stat instead. stat itself
# differs by platform (BSD: `stat -f "%m %N"`; GNU/Linux: `stat -c "%Y %n"`),
# so try BSD then fall back to GNU — otherwise this stall signal silently
# returns nothing under WSL2/Linux and the detector degrades to CPU-only.
NEWEST_FILE_PATH=$(find "$WT" -type f \
  -not -path '*/.git/*' \
  -not -path '*/__pycache__/*' \
  -not -path '*/venv/*' \
  -not -path '*/node_modules/*' \
  -not -name '*.pyc' 2>/dev/null \
  | xargs -I {} sh -c 'stat -f "%m %N" "$1" 2>/dev/null || stat -c "%Y %n" "$1" 2>/dev/null' _ {} \
  | sort -rn | head -1)
NEWEST_FILE_TS=${NEWEST_FILE_PATH%% *}
NEWEST_FILE_PATH=${NEWEST_FILE_PATH#* }
if [ -n "$NEWEST_FILE_TS" ]; then
  FILE_AGE_MIN=$(( (NOW - ${NEWEST_FILE_TS%.*}) / 60 ))
  if [ "$FILE_AGE_MIN" -gt "$STALL_FILE_MIN" ]; then
    STALL=1
    REASONS+=("no_file_mod_for_${FILE_AGE_MIN}m")
  fi
else
  FILE_AGE_MIN=-1
fi

# 2. Newest commit on the ticket branch (in any worktree under $WT)
NEWEST_COMMIT_TS=0
NEWEST_COMMIT_REPO=""
for repo_dir in "$WT"/*/; do
  [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || continue
  ts=$(git -C "$repo_dir" log -1 --format=%ct 2>/dev/null || echo 0)
  [ -z "$ts" ] && ts=0
  if [ "$ts" -gt "$NEWEST_COMMIT_TS" ]; then
    NEWEST_COMMIT_TS=$ts
    NEWEST_COMMIT_REPO="$(basename "$repo_dir")"
  fi
done
if [ "$NEWEST_COMMIT_TS" -gt 0 ]; then
  COMMIT_AGE_MIN=$(( (NOW - NEWEST_COMMIT_TS) / 60 ))
  if [ "$COMMIT_AGE_MIN" -gt "$STALL_COMMIT_MIN" ] && [ "$FILE_AGE_MIN" -gt "$STALL_FILE_MIN" ]; then
    # Only count commit-age as a stall signal if files are ALSO stale —
    # a worker can be deep inside a long edit (slow rounds) without committing.
    REASONS+=("no_commit_for_${COMMIT_AGE_MIN}m_combined_with_file_stale")
  fi
else
  COMMIT_AGE_MIN=-1
fi

# 3. Suspicious long-running background children (planner / codex / claude -p)
SUSPICIOUS_PIDS=$(ps -ax -o pid,etime,pcpu,command 2>/dev/null \
  | awk -v thresh="$STALL_BG_MIN" '
      function etime_to_min(e,   parts, n, days, hms, hh, mm, ss) {
        # etime formats: MM:SS  HH:MM:SS  D-HH:MM:SS  DD-HH:MM:SS
        if (index(e,"-")) { n=split(e,parts,"-"); days=parts[1]; hms=parts[2] }
        else { days=0; hms=e }
        n=split(hms, parts, ":")
        if (n==3) { hh=parts[1]; mm=parts[2]; ss=parts[3] }
        else if (n==2) { hh=0; mm=parts[1]; ss=parts[2] }
        else return 0
        return days*1440 + hh*60 + mm + ss/60
      }
      {
        etime=$2; pcpu=$3
        if (etime_to_min(etime) >= thresh && pcpu+0 < 1.0) {
          $1=$1; $2=$2; $3=$3
          line=""
          for (i=4;i<=NF;i++) line=line " " $i
          # Tight match: subprocess-style invocations only — exclude the
          # main interactive Claude Desktop process (carries xhigh /
          # claude-opus-4-7 in argv but is NOT a qship subprocess).
          # Subprocess invocations have "claude -p" or "codex exec --model"
          # near the start of argv; Claude Desktop argv is dominated by
          # --user-data-dir / --mcp-config / --plugin-dir.
          if ((line ~ /claude -p / || line ~ /codex exec --model/ || line ~ / --effort xhigh / ) \
              && line !~ /--mcp-config/ \
              && line !~ /--plugin-dir/ \
              && line !~ /Claude Helper/) {
            print $1, etime, pcpu, line
          }
        }
      }')

if [ -n "$SUSPICIOUS_PIDS" ]; then
  STALL=1
  REASONS+=("suspicious_idle_child:$(echo "$SUSPICIOUS_PIDS" | wc -l | tr -d ' ')_proc")
fi

# Output
case "$MODE" in
  --json)
    printf '{"ticket":"%s","stall":%s,"reasons":[%s],"newest_file_min":%s,"newest_file":"%s","newest_commit_min":%s,"newest_commit_repo":"%s","suspicious_pids":"%s"}\n' \
      "$TICKET" \
      "$([ "$STALL" -eq 1 ] && echo true || echo false)" \
      "$([ "${#REASONS[@]}" -gt 0 ] && printf '"%s",' "${REASONS[@]}" | sed 's/,$//')" \
      "$FILE_AGE_MIN" \
      "$NEWEST_FILE_PATH" \
      "$COMMIT_AGE_MIN" \
      "$NEWEST_COMMIT_REPO" \
      "$(echo "$SUSPICIOUS_PIDS" | tr '\n' ';' | sed 's/;$//' | sed 's/"/\\"/g')"
    ;;
  --strict)
    if [ "$STALL" -eq 1 ]; then
      echo "STALL $TICKET reasons=${REASONS[*]} file_age=${FILE_AGE_MIN}m commit_age=${COMMIT_AGE_MIN}m" >&2
      exit 1
    else
      echo "OK $TICKET file_age=${FILE_AGE_MIN}m commit_age=${COMMIT_AGE_MIN}m"
    fi
    ;;
  *)
    echo "=== qship-watchdog $TICKET @ $(date '+%H:%M:%S') ==="
    echo "  newest file: $NEWEST_FILE_PATH"
    echo "  file age:    ${FILE_AGE_MIN}m"
    echo "  newest commit repo: $NEWEST_COMMIT_REPO  (${COMMIT_AGE_MIN}m ago)"
    echo "  verdict:     $([ "$STALL" -eq 1 ] && echo "STALL — ${REASONS[*]}" || echo OK)"
    if [ -n "$SUSPICIOUS_PIDS" ]; then
      echo "  suspicious idle children (>${STALL_BG_MIN}m, <1% CPU, name matches planner/codex/claude-p):"
      echo "$SUSPICIOUS_PIDS" | sed 's/^/    /'
    fi
    ;;
esac

[ "$STALL" -eq 1 ] && exit 1 || exit 0
