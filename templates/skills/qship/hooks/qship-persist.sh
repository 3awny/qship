#!/bin/bash
# qship-persist.sh — outer bash wrapper that keeps re-invoking /qship until
# every named ticket's pipeline is complete. This is the "ralph pattern":
# state lives in the filesystem ({{STATE_ROOT}}/worktrees/<TICKET>/), each
# iteration starts with a fresh Claude context, and the bash loop — not the
# LLM — decides when work is done. Survives context compaction, dropped
# connections, and rogue "I'm done" completion reports.
#
# Usage:
#   qship-persist.sh {{JIRA_PROJECT_KEY}}-42
#   qship-persist.sh {{JIRA_PROJECT_KEY}}-1 {{JIRA_PROJECT_KEY}}-2 {{JIRA_PROJECT_KEY}}-3
#   MAX_ITERS=20 SLEEP_SECONDS=30 qship-persist.sh {{JIRA_PROJECT_KEY}}-42
#
# Completion criteria per ticket: `/qshipcheck <TICKET>` reports PASSED.

set -euo pipefail

# Default GitHub host to the {{COMPANY_SLUG}} enterprise instance so `gh pr create / comment /
# review` calls in Phase 4 hit {{GH_HOST}} rather than github.com. Override at
# invocation time if a ticket genuinely targets github.com (e.g. an OSS repo).
export GH_HOST="${GH_HOST:-{{GH_HOST}}}"

# Mark every spawned `claude -p` invocation as a qship session. The Stop /
# SubagentStop hook (require-pipeline-complete.sh) reads this env to scope its
# blocking behaviour — without it, the hook fires globally and would pressure
# unrelated sessions to delete {{STATE_ROOT}}/worktrees/ entries to clear stale
# blockers. With QSHIP_SESSION=1 set here, only sessions actually spawned by
# this persist loop (and sessions that grep transcript for qship markers) get
# blocked when their pipeline state is incomplete.
export QSHIP_SESSION=1

MAX_ITERS="${MAX_ITERS:-5}"
SLEEP_SECONDS="${SLEEP_SECONDS:-15}"
WORKTREE_ROOT="${QSHIP_WORKTREE_ROOT:-{{STATE_ROOT}}/worktrees}"
LOG_DIR="${QSHIP_PERSIST_LOG_DIR:-{{STATE_ROOT}}/persist-logs}"

if [ "$#" -lt 1 ]; then
  cat <<'USAGE'
Usage: qship-persist.sh <TICKET-ID> [TICKET-ID...]

Env overrides:
  MAX_ITERS          max claude invocations per ticket (default 10)
  SLEEP_SECONDS      sleep between iterations (default 15)
  QSHIP_WORKTREE_ROOT worktree root (default {{STATE_ROOT}}/worktrees)
USAGE
  exit 2
fi

mkdir -p "$LOG_DIR"
tickets=("$@")
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Shared flags for every headless `claude -p` invocation in the loop.
# - --dangerously-skip-permissions: required for unattended execution. Safety is
#   enforced by PreToolUse + Stop hooks (require-phase3-evidence.sh,
#   require-pipeline-complete.sh) and the project permission allowlist, NOT by
#   interactive prompts.
# - --allowedTools: pre-approves MCP tools (Atlassian, Confluence, claude-context)
#   and the core file/shell tools so headless mode doesn't block on missing
#   permissions for tools the qship pipeline needs.
# - --model: select Opus with the 1M-context variant (`[1m]` suffix). The 1M
#   window is critical for the qship orchestrator which carries plans, diffs,
#   and review output across many tool calls. The `opus[1m]` alias auto-tracks
#   the latest Opus release; switch to `claude-opus-4-7[1m]` to pin a specific
#   version. Without --model, headless mode may silently downgrade.
# Autonomy directive injected as a system prompt on every iteration. Without
# this, the orchestrator (especially on large epics) tends to print a wave plan
# and ask the user "inline or persist?" before doing anything — which in headless
# mode silently exits with no work done. The directive below is intentionally
# blunt and refers to the wrapper by name so the model cannot rationalize that
# "maybe a human is watching."
AUTONOMY_DIRECTIVE='BASH-TOOL HANG PREVENTION (read first, applies to EVERY Bash call you make): Claude Code'"'"'s Bash tool waits on the spawned process group'"'"'s `close` event, not `exit` — meaning the tool only returns when ALL inherited stdio pipes are released. If ANY background child holds stdout/stderr open, the Bash tool hangs forever and burns your iteration budget (this stalled {{JIRA_PROJECT_KEY}}-EX07 {{JIRA_PROJECT_KEY}}-EX10 for 67+ minutes on a `head -3` zombie before a supervisor killed it; same class as anomalyco/opencode#20902 and anthropic/claude-code#27401). RULES — NON-NEGOTIABLE: (1) Any command that backgrounds a process MUST close all three stdio: `cmd >/tmp/x.log 2>&1 </dev/null & disown` — never bare `cmd &` or `nohup cmd &`. The redirects close the inherited pipes; `disown` removes job-control reference. (2) For long-running servers, ALSO add `setsid` if available so the process leaves the tool'"'"'s process group entirely: `setsid nohup cmd >/tmp/x.log 2>&1 </dev/null &`. (3) NEVER pipe stdin to `npx ...` — that combo deadlocks the Bash tool (anthropic/claude-code#27401). Use `npx cmd < file.txt` (file redirection) instead. (4) NEVER end a Bash command with `& tail -f log` or `& head -3` style watchers — those inherit pipes from the backgrounded process. Use a separate Bash call to tail the log AFTER the background spawn returns. (5) Test commands that may produce indefinite output (servers, watchers, `tail -f`, `tee`) MUST be wrapped in `timeout 60s cmd` so a hung tool returns control. If the tool returns with timeout exit code 124, that is success — re-run is allowed. Violating any of these = the entire persist iteration burns wall-clock with zero forward progress. If you'"'"'re unsure whether a command might spawn a child that holds pipes, prefix with `(setsid nohup ... </dev/null & disown) >/dev/null 2>&1` as a belt-and-suspenders form. YOU ARE RUNNING UNATTENDED INSIDE qship-persist.sh. There is NO human reading your output. NEVER ask "inline or persist?", "should I proceed?", "which approach do you want?", or any other clarifying question — there is no one to answer. The persist wrapper IS the autonomy mechanism: you ARE the persist loop. If you find yourself about to ask the user anything, instead: (1) pick the option that produces the most complete result, (2) execute it, (3) write progress to {{STATE_ROOT}}/worktrees/<TICKET>/phase2-progress.md so the next iteration can resume. Asking the user counts as a pipeline failure and wastes one of the persist iterations. The qship skill autonomy contract is non-negotiable. Continue working until /qshipcheck reports PASSED — every iteration must make concrete forward progress (Jira fetched, worktree created, code written, tests run, PR opened, etc.). If state already exists at {{STATE_ROOT}}/worktrees/<TICKET>/, READ phase2-progress.md FIRST and resume from the first PENDING row — do not start over. ALWAYS check for {{STATE_ROOT}}/worktrees/<TICKET>/USER_NOTE.md before each phase — it contains user-injected overrides that supersede defaults in the qship skill (e.g., DB targets, scope limits, deferrals). Read it once per iteration and treat its instructions as authoritative for this ticket. CROSS-ITERATION FAILURE LOG (mandatory): {{STATE_ROOT}}/worktrees/<TICKET>/iter-failure-log.md tracks what previous iterations attempted and (if failed) why. READ THIS FILE FIRST every iteration. Do NOT re-attempt anything listed there as a known failure unless you have new information that contradicts the prior diagnosis. After every significant action (especially failed ones), APPEND a one-paragraph summary to that file with: (a) approach taken, (b) outcome, (c) if failed: root cause + what to try instead. Without this, persist iterations re-make the same wrong choices forever — see {{JIRA_PROJECT_KEY}}-EX03 (1.5h wasted re-running broken Playwright selectors across 3 iterations). SUBPROCESS BROWSER GATE (qmanualt): Claude-in-Chrome MCP is bound to the user'"'"'s interactive Claude Code session, not to this `claude --print` subprocess. mcp__Claude_in_Chrome__list_connected_browsers WILL return empty here even when the user has Chrome connected. If the change requires UI evidence and Playwright cannot produce trustworthy results (e.g., needs the external auth provider session, or live-DOM selector inspection that this subprocess cannot do reliably), DO NOT loop forever writing speculative Playwright tests with hallucinated selectors. Per qmanualt: write phase3-evidence-pending-interactive.md, mark Step 14 BLOCKED [needs_interactive_ui_verification], add a QSHIP_SKIP_UI_E2E_PENDING_INTERACTIVE rationale to phase3-evidence.md, and proceed with Phase 4. Do not invent locators against a DOM you have not snapshotted.'

# Build the per-ticket flag array. Done per-ticket (not once globally) so the
# system prompt can include the ticket's specific scope manifest + canaries —
# the require-epic-scope-coverage.sh hook checks for canaries in the diff, so
# the orchestrator must embed them as it implements each child story.
build_claude_flags() {
  local ticket="$1"
  local manifest="$WORKTREE_ROOT/$ticket/expected-children.txt"
  local canary_file="$WORKTREE_ROOT/$ticket/canaries.json"
  local extra_directive=""

  if [ -s "$manifest" ] && [ -s "$canary_file" ]; then
    extra_directive=' SCOPE COVERAGE CONTRACT (non-negotiable, hook-enforced): The require-epic-scope-coverage.sh PreToolUse hook will BLOCK gh pr create / git push if any expected child ticket has zero commits OR if any canary sentinel is missing from the diff. The expected child list is at '"$manifest"'. The canary mapping is at '"$canary_file"' (JSON: ticket → sentinel). For EVERY child you implement, embed its canary string in a code comment in at least one changed file. Example: # qship-canary: QSHIP-CANARY-{{JIRA_PROJECT_KEY}}-XYZ-abc123. Do NOT defer, drop, or rationalize away any child ticket — the hook will reject the PR. If a child genuinely has no work to do, that is a planning error: surface it loudly, do not silently skip.'
  fi

  # Phase 3 evaluator contract — applies whenever required-scenarios.json
  # exists for this ticket. The require-phase3-critic.sh hook spawns a separate
  # haiku-model claude process that scores phase3-evidence.md against the
  # scenario matrix. Plausible-sounding rationales without observable evidence
  # WILL fail the critic.
  local scenarios_file="$WORKTREE_ROOT/$ticket/required-scenarios.json"
  if [ -s "$scenarios_file" ] && [ "$(jq -r '.acceptance_criteria | length' "$scenarios_file" 2>/dev/null || echo 0)" -gt 0 ]; then
    extra_directive="$extra_directive"' PHASE 3 EVALUATOR CONTRACT (non-negotiable, hook-enforced): A separate adversarial critic (qphase3critic skill, haiku) will score phase3-evidence.md against '"$scenarios_file"' before any PR is allowed. The critic runs as a separate process with adversarial framing — it WILL find gaps and reject hand-waving. For EACH acceptance criterion, the matrix has 5 required scenarios (happy_path, negative, boundary, edge, auth). For EACH scenario, phase3-evidence.md must contain at least ONE concrete observable artifact: a curl block with status code + response body, OR a psql/SELECT output, OR a Playwright trace.zip + JSON results path, OR a named pytest function. Generic claims like "covered by unit tests", "no api surface", "no ui surface", "deferred", or "tested implicitly in happy path" will be rejected by the critic — only file the appropriate concrete observation. Read '"$scenarios_file"' BEFORE writing phase3-evidence.md so you know which scenarios to cover. UI-touching tickets must produce concrete browser-driven evidence in {{STATE_ROOT}}/worktrees/'"$ticket"'/test-results/ — one screenshot AND/OR one DOM snapshot per scenario. BROWSER-MCP PRECEDENCE (use the first one that works): (1) Preferred: `mcp__chrome-devtools-attach__*` — attaches to a Chrome instance at http://127.0.0.1:9222 (auto-launched by qshipmaster-run.sh with --user-data-dir=$HOME/.cache/chrome-devtools-mcp-profile). NOTE: under Phase 3'"'"'s default DEV_MODE=true local stack, the external auth provider auth is bypassed regardless, so this is NOT preferred for "real cookies" — it'"'"'s preferred for (a) persistent localStorage across iterations, (b) ~3-5s saved per invocation skipping Chromium cold start, (c) any installed extensions (React DevTools, etc.). Verify with `mcp__chrome-devtools-attach__list_pages` before relying on it; an empty result means Chrome :9222 is down and you should fall back to (2). (2) Fallback (equally valid for DEV_MODE=true testing): `mcp__plugin_playwright_playwright__*` — fresh Chromium, no cookies, works fine under DEV_MODE=true because the stack bypasses auth. If the repo lacks @playwright/test (no playwright.config.ts, no test specs), DO NOT skip Phase 3 — use the MCP browser tools directly: spin up the local server (DEV_MODE=true, DATABASE_URL=postgresql://{{LOCAL_DB_USER}}@localhost:5432/local_acme_corp_db, nohup python serve.py &), then drive the running UI via the MCP tools, capture screenshots + snapshots per scenario, save under test-results/, and reference them in phase3-evidence.md. (3) Never relied on: `mcp__Claude_in_Chrome__*` — single-tenant native messaging host bound to the user'"'"'s interactive Claude Code session, NOT visible in this `claude --print` subprocess. list_connected_browsers WILL return empty here regardless of user state. The critic has chrome-devtools-attach + Playwright MCP access and will navigate the running UI itself to verify your claims.'
  fi

  # EPIC_MODE Phase-1-only override: when running under qshipmaster (epic
  # orchestrator), Phase 2 (review subagents 7.5/8/9/10/11/11.5) and Phase 3
  # (E2E evidence) are BATCHED at wave + epic level on the merged diff —
  # running them per-ticket dispatches 10× redundant subagents covering the
  # same code surfaces. The orchestrator does the per-wave batch and the
  # per-epic final pass. Workers commit Phase 1 implementation, write
  # phase1-complete.flag, and exit. Skipping Phase 2/3 here is the single
  # biggest token win in the entire pipeline.
  local phase1_only_block=""
  if [ "${EPIC_MODE:-false}" = "true" ]; then
    phase1_only_block=' EPIC_MODE PHASE-1-ONLY CONTRACT — HARD PROHIBITION (overrides /qship default flow). Background: qshipmaster {{JIRA_PROJECT_KEY}}-EX07 {{JIRA_PROJECT_KEY}}-EX10 burned an extra ~75 minutes of wall time because the worker ran the full per-ticket Phase 2 inventory (qsimplify, qcheck ×3 agents, qbug ×5 agents, qbcheck, fixes, verification gate) despite EPIC_MODE telling it not to. That was goal drift — the autonomy directive'"'"'s "produce the most complete result" wording overrode the EPIC_MODE skip rule when they conflicted. This block resolves the conflict explicitly: EPIC_MODE WINS. "Most complete result" in EPIC_MODE means "Phase 1 complete and exited," not "every Phase 2 box ticked." CONTRACT FOR THIS TICKET: (a) Read the spec + AC carefully. (b) Implement the change with TDD discipline (write failing test → make it pass → refactor). (c) Run `pytest <new-tests>` and `black --check` ONLY on the files you touched — local sanity, not full review. (d) Commit your work with a clear message. (e) Write a one-paragraph summary to {{STATE_ROOT}}/worktrees/'"$ticket"'/phase1-summary.md (what you implemented, which files touched, which AC the impl covers, any open questions for wave-level review). (f) Touch {{STATE_ROOT}}/worktrees/'"$ticket"'/phase1-complete.flag with the file list. (g) STOP. Exit cleanly. PROHIBITED ACTIONS (each one is a contract violation that wastes the user'"'"'s wall-clock budget — the wave-batch review is doing all of these on the merged diff in ~30 min instead of ~2 hours per ticket): (1) Generating a `phase2-progress.md` file with rows for ANY of: "Simplify", "Reviewer", "Bug Hunter", "Bug Validation", "Fix Issues", "Verification Gate", "Quick E2E", "Memory Capture". If you find yourself writing such a table, STOP — that is the smoking-gun signal that you are about to violate EPIC_MODE. (2) Dispatching ANY Task subagent named code-reviewer, qcheckt, code-simplifier, bug-hunter, logic-error-detector, silent-failure-hunter, race-condition-spotter, root-cause-tracer, edge-case-hunter, security-scanner, or any of the qship/superpowers/feature-dev/pr-review-toolkit review/hunt agents. (3) Invoking ANY of the slash commands /qsimplify, /qcheck, /qbug, /qbcheck, /qcheckt, /qauthtrailingslash, /qmigrationdevcheck, /qe2etest, /qmanualt, /qmemory, /qshipcheck, /qphase3critic. (4) Running `pytest tests/` (full suite) — only `pytest <files-you-touched>` is allowed. (5) Generating `phase3-evidence.md` or `wave-N-phase23-evidence.md` for this ticket. (6) Spinning up the local server (no `python serve.py`, no `nohup … uvicorn`, no Playwright/chrome-devtools MCP calls). (7) Calling `gh pr create` or `git push` — orchestrator handles deliver. SELF-CHECK before every Task() or Bash dispatch: ask "would this still be needed if the wave-batch review re-runs it on the merged diff?" If yes, SKIP IT. The whole point of EPIC_MODE is to run that work ONCE per wave instead of N times per ticket. RECOVERY: if you'"'"'ve already drifted into Phase 2 work this iteration, do NOT roll it back and do NOT continue — just stop the current tool loop, write phase1-summary.md + touch phase1-complete.flag, and exit. The wave-batch review tolerates duplicate work; it does not tolerate the worker spinning forever.'
  fi

  # Advisor block — when QSHIP_USE_ADVISOR=true, give the Sonnet executor
  # access to a Bash helper that consults Opus 4.7 mid-task at decision points.
  # Pattern from Anthropic's advisor-strategy blog post (https://claude.com/blog/the-advisor-strategy):
  # call the advisor BEFORE substantive work, NOT for orientation. The
  # canonical instruction prefix is taken near-verbatim from Anthropic's own
  # system prompt for the advisor tool (Piebald-AI mirror). When Claude Code
  # natively GAs the API advisor tool in --print, this block becomes a hint
  # for that tool instead of the Bash shim.
  local advisor_block=""
  if [ "${QSHIP_USE_ADVISOR:-false}" = "true" ]; then
    local advisor_max="${QSHIP_ADVISOR_MAX_USES:-3}"
    advisor_block=' ADVISOR (Opus 4.7 consultant) — non-negotiable usage rules: You have access to a higher-intelligence advisor backed by Opus 4.7 (1M ctx) via the Bash helper `bash ~/.claude/skills/qship/hooks/qship-consult-opus.sh '"$ticket"' "<question>" [<optional-context-file>]`. The advisor returns ANALYSIS / RECOMMENDATION / CAVEATS. CONTEXT HANDLING: if you do NOT pass a context file, the helper auto-bundles relevant worktree state (ticket spec, required-scenarios.json, phase2-progress.md, phase3-evidence.md, recent git log + diff stats, last iter output tail, last test/lint logs) — this is the smart default for ~90% of consults; the helper picks what matters. ONLY pass an explicit context file when you have a specific artifact the auto-bundle would miss (e.g. a particular SQL query, a stack trace not in the recent logs, a snippet from another repo). Do not re-package what the auto-bundle already sees — that wastes tokens. CALL THE ADVISOR BEFORE substantive work — before writing code that commits to an interpretation, before declaring the plan final, before adopting a non-obvious bug fix, before declaring Phase 3 PASSED. DO NOT call it for orientation (finding files, reading docs, listing tests) — that is your job. DO NOT call it on routine work (renaming a variable, adding an import, running tests). DO NOT re-ask the same question — the advisor cannot remember between calls; if its first answer was insufficient, refine your question with NEW context (different angle, narrower scope). Hard cap: '"$advisor_max"' calls per ticket — exceeding this returns a stub. Each call burns one Opus 4.7 session (~5-15K input tokens), so be deliberate. Recommended decision points (use at most ~2 of these per iter): (1) finalising the Phase 1 plan when AC is ambiguous or the codebase has multiple plausible patterns; (2) Phase 2 review subagent disagreement / mid-bug-hunt root-cause uncertainty; (3) before Phase 3 PASSED on tickets with subtle data-shape or concurrency invariants. The advisor receives no tools — it only reasons. After receiving the verdict, decide for yourself whether to follow it; the advisor can be wrong. Log a one-line note in your iter output stating which advisor consult guided which decision so the audit trail is clear.'
  fi

  # Cross-epic learnings — pattern from ralph-zero (procedural memory across
  # sessions). qshipmaster appends wave-fix root causes to AGENTS.md after
  # every Phase 2 fix iteration; we fold the most recent ~15 entries into the
  # autonomy directive so workers see prior pitfalls before running. Capped to
  # avoid context blowup.
  local agents_file="$HOME/.claude/skills/qshipmaster/AGENTS.md"
  local memory_block=""
  if [ -s "$agents_file" ]; then
    local recent
    # Cap at 5 most-recent learnings (was 15). Each entry is ~150 tokens of
    # ROOT_CAUSE/FIX/RULE; more than 5 buys diminishing returns and inflates
    # the per-call system prompt across every opus[1m] invocation.
    recent=$(tac "$agents_file" 2>/dev/null | awk '
      /^## / { count++; if (count > 5) exit }
      { print }
    ' | tac 2>/dev/null || tail -80 "$agents_file")
    if [ -n "$recent" ]; then
      memory_block=' CROSS-EPIC LEARNINGS (procedural memory from prior qshipmaster runs — read carefully, these rules came from real failures): '"$(printf '%s' "$recent" | tr '\n' ' ' | tr -s ' ')"
    fi
  fi

  # Model strategy (updated alongside /qshipcodex consolidation):
  # - Default iter loop = Opus 4.7 1M context (`opus[1m]`) at `medium`
  #   reasoning effort. Per-ticket implementation benefits from the larger
  #   context window (full plan + memory + diff stays in-prompt) and Opus's
  #   stronger code reasoning; `medium` effort keeps spend tractable while
  #   still beating Sonnet on cross-file invariants.
  # - Override with QSHIP_ITER_MODEL=sonnet (or any other model id) when you
  #   want a cheaper executor, and QSHIP_ITER_EFFORT=high/xhigh/low to tune
  #   reasoning depth.
  # - When the orchestrator was invoked with `provider=codex`, Step 7's inner
  #   loop is delegated to `codex exec` per task (see qship/step7-codex-
  #   override.md) — this `--model` only governs the surrounding Claude work.
  CLAUDE_FLAGS=(
    --print
    --dangerously-skip-permissions
    --allowedTools 'mcp__*,Bash,Read,Edit,Write,Glob,Grep,Task,TodoWrite,WebSearch,WebFetch'
    --model "${QSHIP_ITER_MODEL:-opus[1m]}"
    --effort "${QSHIP_ITER_EFFORT:-medium}"
    --append-system-prompt "${AUTONOMY_DIRECTIVE}${phase1_only_block}${advisor_block}${memory_block}${extra_directive}"
  )
}

# Lightweight CLAUDE_FLAGS variant for /qshipcheck — verdict-only, no
# implementation. Haiku 4.5 is the right tier: pattern-matches PASSED/FAILED
# in evidence files, ~10x cheaper than Opus, doesn't need the giant autonomy
# directive or memory block. Override via QSHIP_CHECK_MODEL.
build_check_flags() {
  CHECK_FLAGS=(
    --print
    --dangerously-skip-permissions
    --allowedTools 'Bash,Read,Glob,Grep'
    --model "${QSHIP_CHECK_MODEL:-claude-haiku-4-5-20251001}"
  )
}

# Run a `claude --print` invocation under a hard wall-clock timeout. A wedged
# headless session (network blip, MCP hang, model latency, prompt loop) will
# otherwise hang forever — the persist loop has no upper bound on a single
# claude call, so one stuck child silently burns the entire wave budget.
# Default 2 hours; override via QSHIP_CLAUDE_TIMEOUT_SEC.
run_claude_timeboxed() {
  local secs="${QSHIP_CLAUDE_TIMEOUT_SEC:-7200}"
  local timeout_bin
  timeout_bin="$(command -v timeout || command -v gtimeout || true)"
  if [ -z "$timeout_bin" ]; then
    claude "$@"
    return $?
  fi
  "$timeout_bin" --kill-after=30s "$secs" claude "$@"
  local rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "[qship-persist] WARNING: claude --print exceeded ${secs}s wall-clock — killed by timeout (rc=$rc)" >&2
  fi
  return "$rc"
}

# Fetch acceptance criteria for a ticket and decompose them into a 5-category
# required-scenarios matrix. Runs as a separate haiku invocation at startup.
# The output (`required-scenarios.json`) is the ground truth the Phase 3 critic
# (require-phase3-critic.sh) scores phase3-evidence.md against. Without this
# file, the critic hook is a no-op — so generating it is what enables Three-
# Agent Harness Phase 3 verification for this ticket.
#
# Schema written:
#   {
#     "ticket": "{{JIRA_PROJECT_KEY}}-123",
#     "acceptance_criteria": [
#       {
#         "ac": "<criterion text>",
#         "scenarios": {
#           "happy_path": "<scenario>",
#           "negative":   "<scenario>",
#           "boundary":   "<scenario>",
#           "edge":       "<scenario>",
#           "auth":       "<scenario>"
#         }
#       }
#     ]
#   }
#
# If a ticket has no parseable AC (e.g. some tasks lack Success Criteria), the
# fetch writes an empty file and the critic gracefully no-ops. This is
# acceptable — the critic complements other Phase 3 gates, it doesn't replace
# them.
fetch_scenarios_matrix() {
  local ticket="$1"
  local persist_log="$LOG_DIR/${ticket}-persist.log"
  local ticket_dir="$WORKTREE_ROOT/$ticket"
  local scenarios_file="$ticket_dir/required-scenarios.json"

  mkdir -p "$ticket_dir"
  if [ -s "$scenarios_file" ]; then
    echo "[$(ts)] [$ticket] scenarios matrix already exists at $scenarios_file — skipping" | tee -a "$persist_log"
    return 0
  fi

  echo "[$(ts)] [$ticket] decomposing acceptance criteria into scenarios matrix..." | tee -a "$persist_log"
  local fetch_log="$LOG_DIR/${ticket}-scenarios-fetch.log"

  # Two-step prompt: (1) obtain the ticket text, (2) decompose into the
  # 5-category scenarios matrix. Done in one haiku call to save round trips.
  # The "obtain the ticket" half depends on the configured tracker
  # ({{TRACKER_TYPE}}): jira → Atlassian MCP; none → a local ticket file the
  # user dropped in the worktree (no tracker MCP exists).
  # FETCH op per the issue-source contract. Add a new provider as one arm here
  # (see qship/references/tracker-contract.md → "Adding a provider").
  local _ticket_src
  case "{{TRACKER_TYPE}}" in
    jira)
      _ticket_src="Use the atlassian MCP. Get cloudId for {{COMPANY_SLUG_LOWER}}.atlassian.net via getAccessibleAtlassianResources. Then call getJiraIssue with issueIdOrKey=$ticket and responseContentFormat=markdown. From the description," ;;
    *)  # none (and reserved providers that fall back to none)
      _ticket_src="tracker={{TRACKER_TYPE}} — there is NO tracker MCP. Read the ticket/spec for $ticket from the FIRST of these that exists: $WORKTREE_ROOT/$ticket/ticket.md, $WORKTREE_ROOT/$ticket/USER_NOTE.md, or ./$ticket.md. If none exist, output {\"ticket\": \"$ticket\", \"acceptance_criteria\": []} and stop. From that text," ;;
  esac
  claude --print --dangerously-skip-permissions \
    --allowedTools 'mcp__*,Read,Glob' \
    --model haiku \
    "$_ticket_src extract every acceptance criterion / success criterion (lines under '## Success Criteria', '## Acceptance Criteria', or bullets in those sections; also pull any 'must', 'shall', 'should' constraints from the body). For EACH criterion, generate 5 concrete test scenarios (one per category): happy_path (the criterion is satisfied), negative (the criterion is violated), boundary (edge of the valid range — empty / max / null / expired), edge (unusual but valid combinations — concurrent, race, retry), auth (request without auth, wrong role, or — in multi-tenant apps — wrong tenant). Output ONLY a JSON object with this schema and NOTHING else: {\"ticket\": \"$ticket\", \"acceptance_criteria\": [{\"ac\": \"<criterion>\", \"scenarios\": {\"happy_path\": \"...\", \"negative\": \"...\", \"boundary\": \"...\", \"edge\": \"...\", \"auth\": \"...\"}}]}. If the ticket has no extractable acceptance criteria, output {\"ticket\": \"$ticket\", \"acceptance_criteria\": []}." \
    > "$fetch_log" 2>&1 || true

  # Strip anything before the first '{' and after the matching final '}', then
  # validate. If the model wrapped the JSON in prose / markdown fences, this
  # extracts the embedded object. If extraction fails, write empty manifest.
  python3 - <<PY > "$scenarios_file" 2>/dev/null || echo '{"ticket":"'"$ticket"'","acceptance_criteria":[]}' > "$scenarios_file"
import json, re, sys
try:
    text = open("$fetch_log").read()
    # Find first balanced JSON object in the output
    start = text.find('{')
    if start < 0:
        print('{"ticket":"$ticket","acceptance_criteria":[]}'); sys.exit(0)
    depth, end = 0, -1
    for i, c in enumerate(text[start:], start):
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: end = i + 1; break
    if end < 0:
        print('{"ticket":"$ticket","acceptance_criteria":[]}'); sys.exit(0)
    obj = json.loads(text[start:end])
    print(json.dumps(obj, indent=2))
except Exception:
    print('{"ticket":"$ticket","acceptance_criteria":[]}')
PY

  local ac_count
  ac_count=$(jq -r '.acceptance_criteria | length' < "$scenarios_file" 2>/dev/null || echo 0)
  if [ "$ac_count" -eq 0 ]; then
    echo "[$(ts)] [$ticket] no AC parsed — phase3-critic will be a no-op for this ticket" | tee -a "$persist_log"
  else
    echo "[$(ts)] [$ticket] scenarios: $ac_count acceptance criteria, $((ac_count * 5)) required scenarios written to $scenarios_file" | tee -a "$persist_log"
  fi
}

# Fetch the list of child stories for a ticket from Jira via Atlassian MCP.
# Skips if manifest already exists (idempotent across re-runs). Uses a separate
# headless claude invocation with haiku for speed/cost — this is just an MCP
# query, not reasoning work.
#
# Writes:
#   $WORKTREE_ROOT/<TICKET>/expected-children.txt — one {{JIRA_PROJECT_KEY}}-NNN per line
#   $WORKTREE_ROOT/<TICKET>/canaries.json         — {"{{JIRA_PROJECT_KEY}}-NNN": "QSHIP-CANARY-..."}
#
# If the ticket is not an Epic (no children), writes an empty manifest and
# skips canary generation. The hook degrades gracefully on empty manifest.
fetch_manifest_and_canaries() {
  local ticket="$1"
  local persist_log="$LOG_DIR/${ticket}-persist.log"
  local ticket_dir="$WORKTREE_ROOT/$ticket"
  local manifest="$ticket_dir/expected-children.txt"
  local canary_file="$ticket_dir/canaries.json"

  mkdir -p "$ticket_dir"
  if [ -s "$manifest" ]; then
    echo "[$(ts)] [$ticket] manifest already exists at $manifest — skipping fetch" | tee -a "$persist_log"
    return 0
  fi

  local fetch_log="$LOG_DIR/${ticket}-manifest-fetch.log"
  # CHILDREN op per the issue-source contract. Add a new provider as one arm
  # here (see qship/references/tracker-contract.md → "Adding a provider").
  case "{{TRACKER_TYPE}}" in
    jira)
      echo "[$(ts)] [$ticket] fetching child manifest from Jira..." | tee -a "$persist_log"
      claude --print --dangerously-skip-permissions \
        --allowedTools 'mcp__*' \
        --model haiku \
        "Use the atlassian MCP. First call getAccessibleAtlassianResources to get the cloudId for {{COMPANY_SLUG_LOWER}}.atlassian.net. Then call searchJiraIssuesUsingJql with jql=\"parent = $ticket\" and fields=[\"summary\"]. Output ONLY the issue keys of the children, one per line, no other text. If $ticket has no children (it is a Story/Task not an Epic), output the literal text NOT_AN_EPIC on a single line." \
        > "$fetch_log" 2>&1 || true ;;
    *)  # none (and reserved providers that fall back to none): no tracker to query.
      if [ -f "$WORKTREE_ROOT/$ticket/children.txt" ]; then
        echo "[$(ts)] [$ticket] tracker={{TRACKER_TYPE}} — reading children from $WORKTREE_ROOT/$ticket/children.txt" | tee -a "$persist_log"
        cp "$WORKTREE_ROOT/$ticket/children.txt" "$fetch_log"
      else
        echo "[$(ts)] [$ticket] tracker={{TRACKER_TYPE}} — no children.txt; treating as a single ticket (NOT_AN_EPIC)" | tee -a "$persist_log"
        echo "NOT_AN_EPIC" > "$fetch_log"
      fi ;;
  esac

  # Extract only {{JIRA_PROJECT_KEY}}-NNN patterns, dedupe, exclude the parent ticket itself.
  grep -oE '{{JIRA_PROJECT_KEY}}-[0-9]+' "$fetch_log" 2>/dev/null \
    | grep -v "^${ticket}\$" \
    | sort -u > "$manifest" || true

  if [ ! -s "$manifest" ]; then
    echo "[$(ts)] [$ticket] no children found (single-story ticket or Jira fetch failed) — scope coverage hook will be a no-op" | tee -a "$persist_log"
    : > "$manifest"  # ensure file exists (empty) so we don't refetch
    return 0
  fi

  local count
  count=$(wc -l < "$manifest" | tr -d ' ')
  echo "[$(ts)] [$ticket] manifest: $count child stories captured at $manifest" | tee -a "$persist_log"

  # Generate canary mapping. Each canary embeds the child id so it's traceable
  # back to its ticket from any diff. 8 hex chars of randomness keeps it short
  # but unique across runs.
  python3 - <<PY > "$canary_file"
import json, secrets, sys
children = [l.strip() for l in open("$manifest") if l.strip().startswith("{{JIRA_PROJECT_KEY}}-")]
canaries = {c: f"QSHIP-CANARY-{c}-{secrets.token_hex(4)}" for c in children}
print(json.dumps(canaries, indent=2))
PY
  echo "[$(ts)] [$ticket] canaries: $(jq 'length' < "$canary_file") sentinels written to $canary_file" | tee -a "$persist_log"
}

# Per-ticket completion check. Returns 0 when /qshipcheck says PASSED.
# In EPIC_MODE Phase-1-only, accept the phase1-complete.flag as proof that the
# worker shipped its slice — full review/E2E happens at wave + epic level.
ticket_is_complete() {
  local ticket="$1"
  local check_log="$LOG_DIR/${ticket}-qshipcheck.log"

  if [ "${EPIC_MODE:-false}" = "true" ]; then
    local ticket_dir="$WORKTREE_ROOT/$ticket"
    local p1_flag="$ticket_dir/phase1-complete.flag"

    # Wrapper-enforced Phase 1 completion: workers occasionally ignore the
    # EPIC_MODE prompt and keep walking the per-ticket phase2-progress.md
    # template into Phase 2 review subagents, burning the entire iteration
    # budget on work the orchestrator does at wave-level anyway (see {{JIRA_PROJECT_KEY}}-EX04
    # wave-2 stall: 5 iters × 1200s timeout while Phase 1 was
    # already DONE on commit 5a4e6bdf). Trust the wrapper, not the worker:
    # if the branch has real commits AND the last Phase-1 step
    # ("7.45 TRD Mirror + Fix") is marked DONE in phase2-progress.md, the
    # wrapper auto-touches phase1-complete.flag so the next ticket_is_complete
    # call promotes to qshipcheck-PASSED.flag and persist exits cleanly.
    if [ ! -f "$p1_flag" ]; then
      local repo_dir
      repo_dir="$(find "$ticket_dir" -mindepth 1 -maxdepth 1 -type d -name '{{COMPANY_SLUG}}-*' 2>/dev/null | head -1)"
      local progress="$ticket_dir/phase2-progress.md"
      if [ -n "$repo_dir" ] && [ -d "$repo_dir/.git" -o -f "$repo_dir/.git" ] && [ -f "$progress" ]; then
        local commits_ahead
        commits_ahead="$(cd "$repo_dir" && git log --oneline develop..HEAD 2>/dev/null | wc -l | tr -d ' ')"
        if [ "${commits_ahead:-0}" -gt 0 ] \
           && grep -qE '^\|[[:space:]]*7\.45[[:space:]]+TRD[[:space:]]+Mirror[[:space:]]*\+[[:space:]]*Fix[[:space:]]*\|[[:space:]]*DONE' "$progress"; then
          (cd "$repo_dir" && git diff --name-only develop..HEAD) > "$p1_flag.tmp" 2>/dev/null
          mv "$p1_flag.tmp" "$p1_flag"
          echo "[$(ts)] [$ticket] EPIC_MODE: wrapper auto-touched phase1-complete.flag (branch has $commits_ahead commits, Step 7.45 DONE) — worker ignored Phase-1-only contract" | tee -a "${persist_log:-/dev/null}" >&2
        fi
      fi
    fi

    if [ -f "$p1_flag" ]; then
      # Atomic done-flag for the orchestrator's wave barrier.
      local flag="$ticket_dir/qshipcheck-PASSED.flag"
      printf 'EPIC_MODE phase1-complete %s\n' "$(ts)" > "$flag.tmp"
      mv "$flag.tmp" "$flag"
      echo "EPIC_MODE: phase1-complete.flag found → ticket marked PASSED for wave barrier" > "$check_log"
      return 0
    fi
    return 1
  fi

  build_check_flags
  if ! run_claude_timeboxed "${CHECK_FLAGS[@]}" "/qshipcheck $ticket" > "$check_log" 2>&1; then
    return 1
  fi

  # Completion detection. qshipcheck's output may contain the word "PASSED" in
  # both directions ("Result: PASSED" vs "FAILED — pipeline NOT runnable to
  # PASSED from this verifier"). The earlier loose `grep PASSED` matched both,
  # which produced false positives — we shipped a "complete" report on a ticket
  # qshipcheck explicitly failed.
  #
  # Robust check: must match a positive verdict pattern AND must NOT contain any
  # explicit failure/missing markers. Both conditions required.
  if grep -qE '(qshipcheck PASSED|Result:[[:space:]]+PASSED|Verdict:[[:space:]]+PASSED|^[[:space:]]*\*?\*?PASSED\*?\*?[[:space:]]*$)' "$check_log" \
     && ! grep -qE '(qshipcheck FAILED|FAILED —|Result:[[:space:]]+FAILED|Verdict:[[:space:]]+FAILED|MISSING|NOT runnable|NOT[[:space:]]+started|PENDING)' "$check_log"; then
    # Atomic flag file — readers (e.g. qshipmaster wave barrier) poll the
    # flag instead of grepping the log. Eliminates fragility from log-format
    # drift. The flag is the discrete completion signal; the log is evidence.
    local ticket_dir="$WORKTREE_ROOT/$ticket"
    mkdir -p "$ticket_dir"
    local flag="$ticket_dir/qshipcheck-PASSED.flag"
    printf '%s\n' "$(ts)" > "$flag.tmp"
    mv "$flag.tmp" "$flag"
    return 0
  fi
  return 1
}

run_one_iteration() {
  local ticket="$1"
  local iter="$2"
  local iter_log="$LOG_DIR/${ticket}-iter-${iter}.log"
  local persist_log="$LOG_DIR/${ticket}-persist.log"

  echo "[$(ts)] [$ticket] iteration $iter — invoking /qship" | tee -a "$persist_log"

  # Cross-iteration failure log: each iter writes a summary of what it tried so
  # the next iter doesn't repeat doomed approaches. Without this, every iter
  # starts from zero context (only the file state) and re-makes the same wrong
  # choice — wasted {{JIRA_PROJECT_KEY}}-EX03 1.5h re-running broken Playwright selectors.
  local failure_log_dir="{{STATE_ROOT}}/worktrees/${ticket}"
  local failure_log="${failure_log_dir}/iter-failure-log.md"
  if [ -d "$failure_log_dir" ] && [ ! -f "$failure_log" ]; then
    cat > "$failure_log" <<EOF
# Cross-iteration failure log — ${ticket}

Each persist iteration appends a one-paragraph summary of what it attempted
and (if it failed) why. Future iterations MUST read this file before
choosing an approach — do NOT re-attempt anything listed below as a known
failure unless you have new information that contradicts the prior diagnosis.

EOF
  fi

  build_claude_flags "$ticket"
  if ! run_claude_timeboxed "${CLAUDE_FLAGS[@]}" "/qship $ticket" > "$iter_log" 2>&1; then
    echo "[$(ts)] [$ticket] iteration $iter — claude exited non-zero (see $iter_log)" | tee -a "$persist_log"
  fi

  # Sanity guard: surface iterations that produced suspiciously little output —
  # the most common cause is a permission/auth bail (e.g. an MCP server that
  # isn't authenticated headlessly), and silently looping on that wastes the
  # entire MAX_ITERS budget.
  local log_size
  log_size=$(wc -c < "$iter_log" | tr -d ' ')
  if [ "$log_size" -lt 200 ]; then
    {
      echo "[$(ts)] [$ticket] iteration $iter produced only ${log_size} bytes of output — likely a permission/auth bail"
      echo "--- iter $iter content ---"
      cat "$iter_log"
      echo "--- end iter $iter content ---"
    } | tee -a "$persist_log"
  fi
}

overall_status=0
for ticket in "${tickets[@]}"; do
  if ! [[ "$ticket" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "skipping invalid ticket id: $ticket" >&2
    overall_status=1
    continue
  fi

  persist_log="$LOG_DIR/${ticket}-persist.log"
  echo "[$(ts)] [$ticket] starting persistence loop (max $MAX_ITERS iterations)" | tee -a "$persist_log"

  # Fetch the planned scope BEFORE the orchestrator can tamper with it. The
  # require-epic-scope-coverage.sh hook reads the resulting manifest at
  # gh pr create time and blocks if delivered scope < planned scope.
  fetch_manifest_and_canaries "$ticket"

  # Decompose acceptance criteria into a 5-category scenario matrix. Read by
  # the require-phase3-critic.sh hook (the "evaluator" leg of Anthropic's
  # Three-Agent Harness). Without this, the critic hook is a no-op.
  fetch_scenarios_matrix "$ticket"

  iter=0
  done_flag=0
  while [ "$iter" -lt "$MAX_ITERS" ]; do
    iter=$((iter + 1))

    if ticket_is_complete "$ticket"; then
      echo "[$(ts)] [$ticket] /qshipcheck PASSED on iteration $iter — pipeline complete" | tee -a "$persist_log"
      done_flag=1
      break
    fi

    run_one_iteration "$ticket" "$iter"

    # Breathing room between invocations so the Postgres provider/Azure rate limits don't bite.
    sleep "$SLEEP_SECONDS"
  done

  if [ "$done_flag" -ne 1 ]; then
    # Last-chance salvage: in EPIC_MODE, the wrapper-enforced auto-promote
    # in ticket_is_complete may not have run on the final iteration (loop
    # condition fails before the next ticket_is_complete call). Run one
    # final check so a finished Phase-1 ticket isn't reported as GAVE UP
    # just because the worker ate iterations on forbidden Phase-2 work.
    if ticket_is_complete "$ticket"; then
      echo "[$(ts)] [$ticket] /qshipcheck PASSED on post-loop salvage check — pipeline complete" | tee -a "$persist_log"
      done_flag=1
    else
      echo "[$(ts)] [$ticket] GAVE UP after $MAX_ITERS iterations — /qshipcheck still failing" | tee -a "$persist_log"
      echo "  Inspect $LOG_DIR/${ticket}-*.log for details. Worktree: $WORKTREE_ROOT/$ticket" | tee -a "$persist_log"
      overall_status=1
    fi
  fi
done

exit "$overall_status"
