#!/usr/bin/env bash
# eval.sh — behavioral eval harness for the qship pipeline (golden-set + LLM-as-judge).
#
# The CI gates check that skills are well-FORMED. This checks that the pipeline
# still BEHAVES well after a prose change. See evals/README.md for the model.
#
# Modes:
#   --check            (default) Validate fixtures + rubric structure. No tokens,
#                      no claude. CI runs this — it catches scaffold rot, not behavior.
#   --list             List the fixtures and exit.
#   --judge            Score one fixture's already-produced artifacts with an
#                      LLM-as-judge. Requires: claude CLI.
#                      Needs: --fixture <id> --artifacts <dir>
#   --run              For each fixture: (optionally) drive the pipeline in a
#                      sandbox repo, then judge the artifacts. Needs --repo <dir>
#                      and claude + an installed qship. Spends tokens, so the
#                      pipeline-exec step only runs when QSHIP_EVAL_EXEC=1;
#                      otherwise --run prints the plan (a dry run) and exits.
#
# Env:
#   QSHIP_EVAL_JUDGE   judge model (default: claude-opus-4-8)
#   QSHIP_EVAL_EXEC=1  actually execute the pipeline during --run (else dry run)
#
# Usage:
#   bash scripts/eval.sh --check
#   bash scripts/eval.sh --judge --fixture 001-add-list-endpoint --artifacts /path/to/artifacts
#   QSHIP_EVAL_EXEC=1 bash scripts/eval.sh --run --repo /path/to/sandbox

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVAL_DIR="$REPO_ROOT/evals"
FIXTURES_DIR="$EVAL_DIR/fixtures"
RUBRIC="$EVAL_DIR/rubric.md"
RESULTS_DIR="$EVAL_DIR/results"
JUDGE_MODEL="${QSHIP_EVAL_JUDGE:-claude-opus-4-8}"

MODE="check"; FIXTURE=""; ARTIFACTS=""; SANDBOX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)     MODE="check" ;;
    --list)      MODE="list" ;;
    --judge)     MODE="judge" ;;
    --run)       MODE="run" ;;
    --fixture)   FIXTURE="${2:-}"; shift ;;
    --artifacts) ARTIFACTS="${2:-}"; shift ;;
    --repo)      SANDBOX="${2:-}"; shift ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
ok()    { green "  ✓ $1"; }
bad()   { red   "  ✗ $1"; }

list_fixtures() { find "$FIXTURES_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | sort; }

# ---- --check : validate the scaffold (CI-safe, no tokens) -----------------
validate_scaffold() {
  local fail=0 n=0
  [[ -f "$RUBRIC" ]] || { bad "rubric missing: $RUBRIC"; fail=1; }
  grep -q '^## Dimensions' "$RUBRIC" 2>/dev/null || { bad "rubric has no '## Dimensions' section"; fail=1; }
  grep -q '^## Judge output contract' "$RUBRIC" 2>/dev/null || { bad "rubric has no judge output contract"; fail=1; }
  [[ -d "$FIXTURES_DIR" ]] || { bad "fixtures dir missing"; exit 1; }

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n=$((n + 1))
    local base; base="$(basename "$f")"
    local missing=""
    grep -qE '^# .+'                       "$f" || missing="$missing title;"
    grep -qE '^## Acceptance Criteria'     "$f" || missing="$missing acceptance-criteria;"
    grep -qE '^## Expected pipeline behavior' "$f" || missing="$missing expected-behavior;"
    if [[ -n "$missing" ]]; then bad "$base — missing: $missing"; fail=1; else ok "$base"; fi
  done <<< "$(list_fixtures)"

  if [[ "$n" -eq 0 ]]; then bad "no fixtures found in $FIXTURES_DIR"; fail=1; fi
  echo "---"
  if [[ "$fail" -ne 0 ]]; then red "eval scaffold INVALID"; exit 1; fi
  green "eval scaffold OK ($n fixture(s), rubric present)"
}

require_claude() {
  command -v claude >/dev/null 2>&1 || { red "claude CLI not found — required for --$MODE"; exit 3; }
}

# ---- build the judge prompt for one fixture + its artifacts ---------------
build_judge_prompt() {
  local fixture_file="$1" artifacts_dir="$2"
  printf 'You are an exacting senior engineer scoring an automated pipeline run.\n\n'
  printf '=== RUBRIC ===\n'; cat "$RUBRIC"
  printf '\n\n=== FIXTURE (the ticket + expected behavior) ===\n'; cat "$fixture_file"
  printf '\n\n=== PRODUCED ARTIFACTS (under %s) ===\n' "$artifacts_dir"
  if [[ -d "$artifacts_dir" ]]; then
    # Concatenate the artifacts the pipeline writes, capped so the prompt stays sane.
    find "$artifacts_dir" -type f \( -name '*.md' -o -name '*.json' -o -name '*.txt' -o -name '*.log' \) \
      2>/dev/null | sort | while IFS= read -r a; do
        printf '\n--- %s ---\n' "${a#$artifacts_dir/}"; head -c 20000 "$a"
      done
  else
    printf '(no artifacts directory found — score what is missing accordingly)\n'
  fi
  printf '\n\n=== TASK ===\nScore strictly per the rubric. Output ONLY the JSON object from the rubric'\''s "Judge output contract".\n'
}

judge_one() {
  local id="$1" artifacts_dir="$2"
  local fixture_file="$FIXTURES_DIR/$id.md"
  [[ -f "$fixture_file" ]] || { red "no such fixture: $id"; exit 2; }
  require_claude
  mkdir -p "$RESULTS_DIR"
  local out="$RESULTS_DIR/$id.json"
  echo "==> Judging $id (model: $JUDGE_MODEL)"
  build_judge_prompt "$fixture_file" "$artifacts_dir" \
    | claude -p --model "$JUDGE_MODEL" > "$out" 2>/dev/null
  if grep -q '"verdict"' "$out" 2>/dev/null; then
    green "  scored → $out"; grep -oE '"verdict"[^,]*' "$out" | head -1 | sed 's/^/  /'
  else
    red "  judge did not return a parseable verdict (see $out)"; return 1
  fi
}

run_all() {
  [[ -n "$SANDBOX" ]] || { red "--run needs --repo <sandbox dir>"; exit 2; }
  [[ -d "$SANDBOX" ]] || { red "sandbox repo not found: $SANDBOX"; exit 2; }
  local installed="${SKILLS_ROOT:-$HOME/.claude/skills}/qship"
  [[ -d "$installed" ]] || { red "qship not installed at $installed — run setup.sh first"; exit 3; }

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local id; id="$(basename "$f" .md)"
    echo "==> Fixture $id"
    local state="${QSHIP_STATE_ROOT:-/tmp/qship-eval}/$id"
    if [[ "${QSHIP_EVAL_EXEC:-0}" == "1" ]]; then
      require_claude
      echo "  executing pipeline (tracker=none) against $SANDBOX ..."
      # tracker=none consumes a local spec file directly; drive the installed skill.
      ( cd "$SANDBOX" && claude -p --dangerously-skip-permissions \
          "/qship $f" ) || red "  pipeline run errored for $id (judging whatever artifacts exist)"
      judge_one "$id" "$state" || true
    else
      echo "  [dry run] would: cd $SANDBOX && claude -p --dangerously-skip-permissions \"/qship $f\""
      echo "  [dry run] then: judge artifacts under $state against the rubric"
      echo "  set QSHIP_EVAL_EXEC=1 to actually run (spends tokens)."
    fi
  done <<< "$(list_fixtures)"
}

case "$MODE" in
  check) validate_scaffold ;;
  list)  list_fixtures | sed 's#.*/##; s/\.md$//' ;;
  judge)
    [[ -n "$FIXTURE" && -n "$ARTIFACTS" ]] || { red "--judge needs --fixture <id> --artifacts <dir>"; exit 2; }
    judge_one "$FIXTURE" "$ARTIFACTS" ;;
  run)   run_all ;;
esac
