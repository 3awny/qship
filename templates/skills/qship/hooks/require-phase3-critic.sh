#!/bin/bash
# PreToolUse hook: invoke the Phase 3 adversarial Evaluator (qphase3critic)
# before allowing PR creation / push of an epic branch.
#
# This is the "evaluator" leg of Anthropic's Three-Agent Harness pattern. The
# orchestrator (generator) wrote phase3-evidence.md; this hook spawns a SEPARATE
# `claude -p` process with adversarial framing and haiku model to score whether
# the evidence covers every required scenario derived from the AC matrix.
#
# Wire in ~/.claude/settings.json under hooks.PreToolUse for matcher "Bash".
# Input on stdin: {"tool_input": {"command": "<the bash command>"}}.
# Output:
#   allow → exit 0 with {"continue": true}
#   block → exit 0 with {"decision": "block", "reason": "<scenarios+JSON>"}
#
# Triggers on the same Phase-4 verbs as require-phase3-evidence.sh:
#   gh pr create, gh pr edit, gh pr comment, git push origin <{{JIRA_PROJECT_KEY}}-...>
#
# Graceful degradation:
#   - No required-scenarios.json    → no-op (scope/AC matrix not generated; e.g. single-story ticket without AC)
#   - Critic invocation fails        → fail open with a warning (better than blocking valid PRs on evaluator infra issues)
#   - Critic returns malformed JSON  → fail open with a warning
#
# Cost: ~$0.005 per invocation (haiku, ~5K input + 1K output tokens). Runs once
# per attempted PR push, not per iteration.

set -eo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./qship-evidence-lib.sh
source "$HOOK_DIR/qship-evidence-lib.sh"

WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
CRITIC_TIMEOUT="${QSHIP_CRITIC_TIMEOUT:-240}"   # seconds — bumped from 90 (haiku
                                                # reading 25KB evidence + diff
                                                # cross-check exceeds 90s reliably)
# Must be numeric: it is interpolated into a perl alarm() below, so a non-numeric
# value (from the env override) could inject perl. Fall back to the default.
[[ "$CRITIC_TIMEOUT" =~ ^[0-9]+$ ]] || CRITIC_TIMEOUT=240
CRITIC_LOG_DIR="${QSHIP_PERSIST_LOG_DIR:-{{STATE_ROOT}}/persist-logs}"

emit_continue() { echo '{"continue": true}'; exit 0; }
emit_block() { jq -Rn --arg r "$1" '{decision: "block", reason: $r}'; exit 0; }

# Read full hook input — needed to dispatch on hook_event_name and tool_name.
hook_input=$(cat 2>/dev/null || echo '{}')
hook_event=$(echo "$hook_input" | jq -r '.hook_event_name // ""' 2>/dev/null || true)
tool_name=$(echo "$hook_input" | jq -r '.tool_name // ""' 2>/dev/null || true)
cmd=$(echo "$hook_input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
edit_path=$(echo "$hook_input" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || true)

# Two trigger paths:
#   1. PreToolUse on Bash matching git push / gh pr create|edit|comment   (legacy gate at PR-create time)
#   2. PostToolUse on Edit|Write of phase3-evidence.md                    (NEW: catches the orchestrator the moment it
#                                                                          finalizes evidence, even if it never pushes —
#                                                                          closes the trapdoor used by {{JIRA_PROJECT_KEY}}-533's run)
ticket=""
trigger=""

case "$hook_event" in
  PostToolUse)
    case "$tool_name" in
      Edit|Write|MultiEdit)
        case "$edit_path" in
          */qship-worktrees/*/phase3-evidence.md)
            ticket=$(echo "$edit_path" | sed -n 's|.*/qship-worktrees/\([^/]*\)/phase3-evidence.md|\1|p')
            trigger="PostToolUse:phase3-evidence-write"
            ;;
        esac
        ;;
    esac
    ;;
  PreToolUse|"")
    case "$cmd" in
      *"gh pr create"*|*"gh pr edit"*|*"git push"*" {{JIRA_PROJECT_KEY}}-"*|*"gh pr comment"*)
        ticket=$(echo "$cmd" | grep -oE '{{JIRA_PROJECT_KEY}}-[0-9]+' | head -1 || true)
        trigger="PreToolUse:phase4-verb"
        ;;
    esac
    ;;
esac

[ -z "$ticket" ] && emit_continue

ticket_dir="$WORKTREE_ROOT/$ticket"
scenarios_file="$ticket_dir/required-scenarios.json"
evidence_file="$ticket_dir/phase3-evidence.md"

# No scenarios manifest → degraded mode. Don't block.
[ -s "$scenarios_file" ] || emit_continue
# No evidence file → not our job (require-phase3-evidence.sh handles that).
[ -s "$evidence_file" ] || emit_continue

# === DETERMINISTIC EVIDENCE-FLOOR (runs BEFORE haiku critic) ============
# Cheap, fast, no LLM. Counts artifacts in test-results/ and asserts a minimum
# proportional to scenario count. Catches the failure mode where the
# orchestrator writes elaborate prose claiming N scenarios but produces only ~4
# real artifacts (which is exactly what {{JIRA_PROJECT_KEY}}-533 did). The haiku critic can be
# talked around on text reasoning; this floor cannot.
floor_err=$(evidence_floor_check "$ticket" "$ticket_dir" 2>&1 1>/dev/null || true)
if [ -n "$floor_err" ]; then
  emit_block "$floor_err"$'\n\n'"This is a HARD floor that runs BEFORE the LLM critic. Capture more concrete per-scenario artifacts (screenshots, curl outputs, psql dumps) before retrying."
fi

mkdir -p "$CRITIC_LOG_DIR"
critic_out="$CRITIC_LOG_DIR/${ticket}-phase3-critic.json"
critic_log="$CRITIC_LOG_DIR/${ticket}-phase3-critic.log"

# Compose the critic invocation. The adversarial system prompt is inlined here
# directly — earlier versions called a separate `qphase3critic` skill but
# headless claude couldn't discover it (nested skill directories aren't loaded
# by skill discovery). Inlining keeps the hook self-contained.
critic_system_prompt='You are a SKEPTICAL adversarial QA reviewer. Your job is to find what is MISSING from Phase 3 evidence. You assume the implementer cut corners. You distrust plausible-sounding rationalizations. You demand concrete observable evidence — not claims about evidence.

For EACH scenario in required-scenarios.json, classify the evidence:
- covered: phase3-evidence.md cites a concrete observable artifact PROVING that exact scenario was tested at runtime — a curl block with HTTP method+URL+status+response body, OR a psql/SELECT row dump, OR a Playwright trace.zip + JSON results path with a named test for the scenario, OR a Playwright MCP screenshot showing the scenario triggered (NOT just a page load)
- partial: some related evidence exists but does not prove THIS scenario — e.g. unit test references, code-path arguments, claims like "covered by existing tests"
- missing: no evidence at all OR only hand-wavy rationalization OR a "no api/ui surface" claim contradicted by the diff touching API/UI files

ANTI-RATIONALIZATION rules — count these as MISSING:
- "Jest test covers this routing" → Jest is Phase 2 unit testing, NOT Phase 3 runtime evidence
- "covered by code path argument" → reading the code is not testing it
- "tested implicitly in happy path" → edge cases need their own assertions
- "implementation guard prevents this" → prevention by design ≠ runtime test
- "Playwright snapshot of the page" without showing the scenario element triggered (e.g. wizard opened, button clicked, alert visible) → page load is not scenario coverage
- "code path is identical to other tested case" → routing equivalence claims do not satisfy Phase 3
- "no api surface" or "no ui surface" → cross-check git diff; if API/UI files changed, the rationale is FALSE

Output ONLY a JSON object, NO prose, NO markdown fences:
{
  "uncovered_count": <int>,
  "scenarios": [
    {"ac": "<text>", "category": "happy_path|negative|boundary|edge|auth", "scenario": "<text>", "status": "covered|partial|missing", "evidence_seen": "<brief>", "gap": "<what is missing>"}
  ],
  "summary": "<1-2 sentence verdict>"
}

If you produce ANY non-JSON output, the hook will fail-CLOSED (block) — your only valid output is the JSON object.'

critic_prompt="You are evaluating Phase 3 evidence for ticket ${ticket}.

REQUIRED SCENARIOS MANIFEST: {{STATE_ROOT}}/worktrees/${ticket}/required-scenarios.json
EVIDENCE FILE TO SCORE:      {{STATE_ROOT}}/worktrees/${ticket}/phase3-evidence.md
EVIDENCE ARTIFACTS DIR:      {{STATE_ROOT}}/worktrees/${ticket}/test-results/ (if exists)

Use Read/Bash to inspect both files. Cross-check phase3-evidence.md claims against the diff:
  for each repo under {{STATE_ROOT}}/worktrees/${ticket}/{{COMPANY_SLUG}}-*; do
    git -C \$repo diff --name-only {{JIRA_PROJECT_KEY}}-EX13-example-feature..HEAD || git -C \$repo diff --name-only develop..HEAD
  done

If a 'no ui surface' rationale appears, validate it: the diff must NOT contain *.tsx, *.jsx, **/components/**, **/dash_pages/**.
If a 'no api surface' rationale appears, validate it: the diff must NOT contain **/api/**, **/routers/**, **/schemas/**.

Apply the rubric in the system prompt. Output ONLY the JSON object."

# Run the critic in a subshell with a timeout so a hanging haiku call cannot
# block the user forever. perl is used for portability of the timeout (macOS
# doesn't ship `timeout` by default).
perl -e '
  my $pid = fork();
  if ($pid == 0) { exec @ARGV; exit 1; }
  local $SIG{ALRM} = sub { kill 9, $pid; exit 124; };
  alarm '"$CRITIC_TIMEOUT"';
  waitpid($pid, 0);
  exit ($? >> 8);
' \
  claude --print --dangerously-skip-permissions \
    --allowedTools 'Bash,Read,Glob,Grep,mcp__plugin_playwright_playwright__*' \
    --model haiku \
    --append-system-prompt "$critic_system_prompt" \
    "$critic_prompt" \
  > "$critic_out" 2> "$critic_log" || critic_exit=$?
critic_exit="${critic_exit:-0}"

# Fail CLOSED on critic infra error. The earlier fail-open mode silently let
# bad evidence through (verified: {{JIRA_PROJECT_KEY}}-533 shipped a one-screenshot Phase 3
# because the critic returned plain text saying "skill not found" and the hook
# fell through). The point of this gate is to BLOCK on uncertainty.
if [ "$critic_exit" -ne 0 ]; then
  emit_block "phase3-critic infrastructure failure (exit=$critic_exit, log: $critic_log). Phase 4 blocked. Either fix the critic or rerun the loop after the issue is resolved. Stderr: $(head -c 500 "$critic_log" 2>/dev/null)"
fi

# Parse the JSON response with a fallback recovery chain. Haiku occasionally
# wraps the JSON in prose ("Here is my evaluation:\n```json\n{...}\n```\n")
# despite the system prompt forbidding it. Try three strategies before failing:
#   1. Direct: input is already pure JSON.
#   2. Markdown-fence strip: pull content between ```json ... ``` fences.
#   3. Regex extract: greediest brace-balanced object via grep -ozE.
# If all three fail, fail CLOSED — but normalize whichever succeeds back to
# $critic_out so downstream jq calls work uniformly.
recover_json() {
  local in="$1"
  local out="$2"
  if jq -e . "$in" >/dev/null 2>&1; then
    cp "$in" "$out"
    return 0
  fi
  # Strategy 2: extract markdown-fenced JSON block.
  local fenced
  fenced=$(sed -n '/```json/,/```/p' "$in" | sed '1d;$d')
  if [ -n "$fenced" ] && printf '%s' "$fenced" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$fenced" > "$out"
    return 0
  fi
  # Strategy 3: regex-extract the largest balanced JSON object. perl handles
  # nested braces; grep -oE alone cannot.
  local extracted
  extracted=$(perl -0777 -ne 'if (/(\{(?:[^{}]|(?1))*\})/s) { print $1 }' "$in" 2>/dev/null)
  if [ -n "$extracted" ] && printf '%s' "$extracted" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$extracted" > "$out"
    return 0
  fi
  return 1
}

critic_recovered="$CRITIC_LOG_DIR/${ticket}-phase3-critic.clean.json"
if ! recover_json "$critic_out" "$critic_recovered"; then
  emit_block "phase3-critic returned non-JSON output (see $critic_out). All recovery strategies failed (direct parse, markdown-fence strip, brace-balanced extract). This is a hard block — the critic may have hit an infra issue or hallucinated prose instead of structured output. Output preview: $(head -c 500 "$critic_out" 2>/dev/null)"
fi
critic_out="$critic_recovered"

uncovered=$(jq -r '.uncovered_count // 0' "$critic_out" 2>/dev/null || echo 0)

if [ "$uncovered" -le 0 ]; then
  emit_continue
fi

# Build a human-readable block message listing each missing/partial scenario.
reason=$(jq -r '
  "Phase 3 EVALUATOR found \(.uncovered_count) uncovered scenario(s) for '"$ticket"'.\n" +
  "Phase 4 (PR create / push) is blocked until each is covered with concrete observable evidence.\n\n" +
  ([.scenarios[] | select(.status != "covered") |
    "- [\(.status | ascii_upcase)] AC: \(.ac)\n" +
    "  category: \(.category)\n" +
    "  scenario: \(.scenario)\n" +
    "  evidence_seen: \(.evidence_seen // "(none)")\n" +
    "  gap: \(.gap)\n"
  ] | join("\n")) +
  "\nVerdict: \(.summary // "")\n\n" +
  "Evidence file: '"$evidence_file"'\n" +
  "Scenarios manifest: '"$scenarios_file"'\n" +
  "Critic raw output: '"$critic_out"'\n\n" +
  "DO NOT rationalize past these gaps. Add concrete runtime evidence (curl / psql / Playwright trace) for each, then retry the PR."
' "$critic_out" 2>/dev/null) || reason="phase3-critic flagged $uncovered uncovered scenarios but reason-rendering failed; see $critic_out"

emit_block "$reason"
