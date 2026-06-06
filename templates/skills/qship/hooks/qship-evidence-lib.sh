# qship-evidence-lib.sh — shared validator for phase3-evidence.md
#
# Sourced by both require-pipeline-complete.sh (Stop hook) and
# require-phase3-evidence.sh (PreToolUse hook on PR-create/push).
# Single source of truth for the evidence schema.
#
# Exposes:
#   validate_phase3_evidence <ticket_id> <ticket_dir>
#     → returns 0 if evidence is sufficient
#     → returns 1 and echoes a one-line reason to stderr otherwise
#
#   phase3_has_missing_e2e <ticket_id> <ticket_dir>
#     → returns 0 if phase3-evidence.md is missing when pipeline-context.json
#       says E2E was required; 1 otherwise.
#     → echoes reason to stderr on 0.

validate_phase3_evidence() {
  local ticket="$1"
  local ticket_dir="$2"
  local evidence="$ticket_dir/phase3-evidence.md"
  local context="$ticket_dir/pipeline-context.json"

  [ ! -f "$evidence" ] && return 0

  if [ ! -s "$evidence" ]; then
    echo "${ticket}: phase3-evidence.md exists but is empty — run /qe2etest and capture evidence." >&2
    return 1
  fi

  # Legacy fallback: no context file → accept any HTTP-ish line or "no network surface".
  if [ ! -s "$context" ]; then
    if grep -qE 'HTTP [12345][0-9][0-9]|curl |httpx |no network surface' "$evidence"; then
      return 0
    fi
    echo "${ticket}: phase3-evidence.md lacks HTTP evidence and no 'no network surface' rationale (no pipeline-context.json)." >&2
    return 1
  fi

  local api_changed ui_changed ui_consumer_changed
  api_changed=$(jq -r '.api_changed // false' "$context")
  ui_changed=$(jq -r '.ui_changed // false' "$context")
  ui_consumer_changed=$(jq -r '.ui_consumer_changed // false' "$context")

  local need_ui=false
  if [ "$ui_changed" = "true" ] || [ "$ui_consumer_changed" = "true" ]; then
    need_ui=true
  fi

  local api_body ui_body
  api_body=$(awk '/^## API Evidence/{flag=1;next}/^## /{flag=0}flag' "$evidence")
  ui_body=$(awk '/^## UI Evidence/{flag=1;next}/^## /{flag=0}flag' "$evidence")

  # --- API check ---
  if [ "$api_changed" = "true" ]; then
    if [ -z "$api_body" ]; then
      echo "${ticket}: api_changed=true but phase3-evidence.md has no '## API Evidence' section." >&2
      return 1
    fi
    if ! echo "$api_body" | grep -qE 'HTTP [12345][0-9][0-9]|curl |httpx '; then
      if ! echo "$api_body" | grep -qE 'no api surface:\s*\S{2,}'; then
        echo "${ticket}: API Evidence section lacks HTTP/curl/httpx lines and has no 'no api surface: <reason>' rationale." >&2
        return 1
      fi
    fi
  fi

  # --- UI check ---
  if [ "$need_ui" = "true" ]; then
    if [ -z "$ui_body" ]; then
      echo "${ticket}: ui_changed or ui_consumer_changed → phase3-evidence.md needs '## UI Evidence' section." >&2
      return 1
    fi

    # Tightened escape hatches:
    #   QSHIP_SKIP_UI_E2E_HUMAN_APPROVED: <YYYY-MM-DD> <reason>   (human only)
    #     - Requires explicit "_HUMAN_APPROVED" suffix the orchestrator cannot
    #       reasonably self-apply, plus an ISO date. The bare loose form
    #       "QSHIP_SKIP_UI_E2E:" is REJECTED — orchestrators were applying it
    #       freely with plausible-sounding reasons. Human override now distinct.
    #
    #   no ui surface: <reason citing changed file paths>
    #     - Still allowed but cross-checked by qphase3critic against the diff.
    #       If diff touches *.tsx/*.jsx/components/dash_pages, the rationale
    #       is contradicted and the LLM critic flags it. This hook accepts
    #       the textual rationale; the critic catches diff-mismatch.
    if echo "$ui_body" | grep -qE 'QSHIP_SKIP_UI_E2E_HUMAN_APPROVED:\s*[0-9]{4}-[0-9]{2}-[0-9]{2}\s+\S{2,}'; then return 0; fi
    if echo "$ui_body" | grep -qE 'no ui surface:\s*\S{2,}'; then return 0; fi
    # Loose self-applicable form is now rejected — orchestrator must produce real evidence
    # OR a human must add the _HUMAN_APPROVED variant.
    if echo "$ui_body" | grep -qE 'QSHIP_SKIP_UI_E2E:\s'; then
      echo "${ticket}: bare 'QSHIP_SKIP_UI_E2E:' rationale is no longer accepted (orchestrator-self-applicable). Use 'QSHIP_SKIP_UI_E2E_HUMAN_APPROVED: <YYYY-MM-DD> <reason>' (human-only) OR produce real Playwright evidence." >&2
      return 1
    fi

    local results_json
    # Exclude markdown delimiters (` * _ ( ) [ ] < > " ') from the captured path so that
    # `test-results/playwright-results.json` (in backticks) doesn't capture the backtick.
    results_json=$(echo "$ui_body" | grep -oE '[^ `*_()<>"'"'"'[]*playwright[^ `*_()<>"'"'"'[]*results?\.json|[^ `*_()<>"'"'"'[]*test-results/[^ `*_()<>"'"'"'[]*\.json' | head -1 || true)
    # Also strip stray backticks/quotes/brackets in case any leak through (defence in depth).
    results_json="${results_json//\`/}"
    results_json="${results_json//\"/}"
    results_json="${results_json//\'/}"
    if [ -n "$results_json" ]; then
      local candidate="$results_json"
      [ -f "$candidate" ] || candidate="$ticket_dir/$results_json"
      if [ -f "$candidate" ]; then
        if jq -e '(.stats.unexpected // 0) == 0 and (.stats.expected // 0) > 0' "$candidate" >/dev/null 2>&1; then
          if echo "$ui_body" | grep -qE 'trace(-[^ ]+)?\.zip'; then
            return 0
          fi
          echo "${ticket}: UI Evidence cites a passing results.json but no trace.zip path — trace is required." >&2
          return 1
        fi
        echo "${ticket}: UI Evidence cites $results_json but stats.unexpected != 0 or stats.expected == 0." >&2
        return 1
      fi
      echo "${ticket}: UI Evidence references $results_json but the file does not exist on disk." >&2
      return 1
    fi

    local trace_ref
    trace_ref=$(echo "$ui_body" | grep -oE '[^ `*_()<>"'"'"'[]*trace(-[^ `*_()<>"'"'"'[]+)?\.zip' | head -1 || true)
    trace_ref="${trace_ref//\`/}"
    trace_ref="${trace_ref//\"/}"
    trace_ref="${trace_ref//\'/}"
    if [ -n "$trace_ref" ]; then
      local tcand="$trace_ref"
      [ -f "$tcand" ] || tcand="$ticket_dir/$trace_ref"
      if [ -f "$tcand" ]; then
        return 0
      fi
      echo "${ticket}: UI Evidence references $trace_ref but the file does not exist on disk." >&2
      return 1
    fi

    echo "${ticket}: UI Evidence section lacks Playwright results.json, trace.zip, or escape rationale (QSHIP_SKIP_UI_E2E / no ui surface)." >&2
    return 1
  fi

  return 0
}

# Deterministic evidence-diversity floor. Does NOT call any LLM. Counts artifacts
# in test-results/ and asserts a minimum proportional to the scenarios manifest.
# This catches the failure mode where the orchestrator writes 20KB of plausible
# prose claiming N scenarios are covered but produces only ~4 actual artifacts
# (curl txt + screenshot). The qphase3critic LLM call can be lenient on text;
# this floor cannot be talked around.
#
#   evidence_floor_check <ticket_id> <ticket_dir>
#     → returns 0 if floor passes (or no scenarios manifest exists)
#     → returns 1 + echoes reason on stderr otherwise
#
# Floor formula: artifact_count >= ceil(scenario_count * QSHIP_EVIDENCE_FLOOR_RATIO)
# Default ratio: 0.5  (every other scenario must produce its own observable artifact)
# Override: export QSHIP_EVIDENCE_FLOOR_RATIO=0.7 etc.
evidence_floor_check() {
  local ticket="$1"
  local ticket_dir="$2"
  local scenarios_file="$ticket_dir/required-scenarios.json"
  local results_dir="$ticket_dir/test-results"
  local ratio="${QSHIP_EVIDENCE_FLOOR_RATIO:-0.5}"

  # No scenarios manifest = legacy or non-Phase-3 ticket. Floor doesn't apply.
  [ ! -s "$scenarios_file" ] && return 0

  local scenario_count
  scenario_count=$(jq -r '
    (.acceptance_criteria // []) | map(.scenarios | values | length) | add // 0
  ' "$scenarios_file" 2>/dev/null || echo 0)

  # No structured scenarios (e.g. ticket has no AC). Floor doesn't apply.
  [ "$scenario_count" -eq 0 ] && return 0

  # Compute required floor (ceil so 25 scenarios * 0.5 = 13).
  local required
  required=$(awk -v n="$scenario_count" -v r="$ratio" 'BEGIN { print int(n*r + 0.999999) }')

  # Count distinct artifacts. Each .png/.txt/.json/.yaml/.html/.zip counts once.
  local artifact_count=0
  if [ -d "$results_dir" ]; then
    artifact_count=$(find "$results_dir" -maxdepth 3 -type f \
      \( -name '*.png' -o -name '*.txt' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \
         -o -name '*.html' -o -name '*.zip' -o -name '*.har' \) 2>/dev/null | wc -l | tr -d ' ')
  fi

  if [ "$artifact_count" -lt "$required" ]; then
    echo "${ticket}: evidence-floor BLOCK — required-scenarios.json declares ${scenario_count} scenarios; floor at ratio ${ratio} demands ≥${required} concrete artifacts (screenshots / curl txt / json / yaml) under ${results_dir}; found ${artifact_count}. Capture more per-scenario observations OR lower QSHIP_EVIDENCE_FLOOR_RATIO if scoping is genuinely smaller." >&2
    return 1
  fi
  return 0
}

phase3_has_missing_e2e() {
  local ticket="$1"
  local ticket_dir="$2"
  local context="$ticket_dir/pipeline-context.json"
  local evidence="$ticket_dir/phase3-evidence.md"

  if [ -f "$evidence" ]; then
    return 1
  fi

  if [ ! -s "$context" ]; then
    echo "${ticket}: phase3-evidence.md and pipeline-context.json both missing — run qship-compute-context.sh then /qe2etest." >&2
    return 0
  fi

  local api ui uic
  api=$(jq -r '.api_changed // false' "$context")
  ui=$(jq -r '.ui_changed // false' "$context")
  uic=$(jq -r '.ui_consumer_changed // false' "$context")

  if [ "$api" = "true" ] || [ "$ui" = "true" ] || [ "$uic" = "true" ]; then
    echo "${ticket}: Phase 2 done but phase3-evidence.md is missing — Phase 3 (E2E) has not run for an API/UI-impacting change." >&2
    return 0
  fi

  return 1
}

# --------------------------------------------------------------------------
# normalize_phase3_heading — canonicalise a near-miss Phase 3 heading.
#
# validate_qe2etest_evidence (below) hard-requires the EXACT literal heading
# `## Phase 3 — /qe2etest evidence` — used BOTH for the presence check AND for
# awk section extraction. A cosmetic wording slip in the agent-written evidence
# (e.g. "## PHASE 3 — E2E", "## Phase 3 E2E", or a hyphen where the em-dash
# belongs) would HALT a wave/epic whose /qe2etest SUBSTANCE is real.
#
# This rewrites the FIRST level-2 "Phase 3" heading to the canonical literal so
# the substance gates (/qe2etest invocation + PASS verdict + banlist) decide
# validity, not the heading wording. No-op if the literal is already present or
# no such heading exists. Relaxes NO check — a mislabeled pytest-only section is
# still rejected on substance.
#
# It MUTATES the evidence file, so call it from the ORCHESTRATOR (run.sh /
# deliver.sh) right before validating. The read-only Stop hook then sees the
# already-canonical file and never has to rewrite anything itself.
# --------------------------------------------------------------------------
normalize_phase3_heading() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Already canonical → nothing to do (and avoids a needless rewrite).
  grep -qF '## Phase 3 — /qe2etest evidence' "$file" 2>/dev/null && return 0
  local tmp="${file}.heading.tmp"
  # toupper() makes the match case-insensitive; ([^0-9]|$) is the portable
  # stand-in for a word boundary after "3" (BSD awk has no \b) so a real
  # "## Phase 30 ..." heading is left alone. Only the first match is rewritten.
  if awk '
        BEGIN { done = 0 }
        !done && toupper($0) ~ /^## +PHASE 3([^0-9]|$)/ {
          print "## Phase 3 — /qe2etest evidence"; done = 1; next
        }
        { print }
      ' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

# --------------------------------------------------------------------------
# ensure_qe2etest_citation — inject a truthful /qe2etest citation when the run
# is PROVEN but the prose token is a near-miss.
#
# validate_qe2etest_evidence requires the Phase 3 SECTION to contain a literal
# `/qe2etest` or `Skill(skill="qe2etest")` token. A worker can run the tool for
# real (tee'ing output to the wave's qe2etest log) yet describe it without the
# exact token — e.g. "qe2etest production-trigger trace" or "wave-N-qe2etest.log"
# (no leading slash, no Skill() form) — and the wave HALTs.
#
# GATED on the run-log existing + non-empty (proof the tool ran): if so, and the
# section lacks the token, inject ONE citation line after the canonical heading.
# Never fabricates (no log → no-op), idempotent, and relaxes NO check — the
# PASS-verdict + banlist gates still decide. Orchestrator-only (mutates the
# evidence file); call AFTER normalize_phase3_heading so the heading is canonical.
#
# Args: $1 evidence file, $2 /qe2etest run-log path.
# --------------------------------------------------------------------------
ensure_qe2etest_citation() {
  local file="$1" log="$2"
  [ -f "$file" ] || return 0
  [ -s "$log" ]  || return 0          # no non-empty run-log → no proof → no-op
  grep -qF '## Phase 3 — /qe2etest evidence' "$file" 2>/dev/null || return 0
  # Mirror the validator: only the Phase 3 SECTION counts for the token.
  local section
  section=$(awk '
    /^## Phase 3 — \/qe2etest evidence/ {flag=1; next}
    /^## / {flag=0}
    flag {print}
  ' "$file")
  if printf '%s\n' "$section" | grep -qE '/qe2etest|Skill\(skill="?qe2etest"?\)'; then
    return 0
  fi
  local tmp="${file}.cite.tmp" logbase
  logbase="$(basename "$log")"
  if awk -v cite="Skill(skill=\"qe2etest\") (/qe2etest) — see ${logbase}" '
        { print }
        !cited && /^## Phase 3 — \/qe2etest evidence/ { print cite; cited = 1 }
      ' "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

# --------------------------------------------------------------------------
# validate_qe2etest_evidence — wave/epic-level evidence validator.
#
# Enforces invariant I1 + I8 from qshipmaster SKILL.md: Phase 3 evidence MUST
# come from /qe2etest, NOT from pytest, TestClient, raw curl, or psql.
#
# Args:
#   $1  evidence file path (e.g. {{STATE_ROOT}}/epic-X/wave-N-phase23-evidence.md
#                                  or {{STATE_ROOT}}/epic-X/epic-phase3-evidence.md)
#   $2  label for error messages (e.g. "wave 4" or "epic")
#   $3  (optional) merged-diff-against-base; if set, supervisor cross-checks
#       any "no qe2etest surface" rationale against actual diff content.
#       Format: git ref range e.g. "develop..HEAD"
#   $4  (optional) git working dir for the diff check above.
#
# Returns 0 if evidence satisfies I1/I8, 1 + stderr reason otherwise.
#
# The contract (all required):
#   1. File exists and is non-empty.
#   2. Contains `## Phase 3 — /qe2etest evidence` heading (EXACT literal —
#      em-dash, not hyphen; mismatch is the most common silent skip).
#   3. Inside that section, contains EITHER:
#      (a) a literal `/qe2etest` invocation line AND a `PASS` (or `FAIL`) verdict
#          line within ~40 lines of the heading, OR
#      (b) a single line `no qe2etest surface: <reason>` (lowercase, with reason
#          ≥10 chars). When $3 + $4 are provided, cross-check the rationale
#          against the diff: if the diff touches FastAPI/React/fetchJson/alembic
#          columns, the "no qe2etest surface" claim is REJECTED.
#   4. Phase-3-section banlist: the section MUST NOT cite pytest, TestClient,
#      raw `curl` one-offs, or psql `SELECT` blocks as the PRIMARY method
#      column. These are Phase 2 verification — citing them in the Phase 3
#      section masks a missing /qe2etest run.
#
#      Allowed exception: a SCENARIO ROW whose method column literally reads
#      `qe2etest:<...>` may MENTION pytest/curl/psql as a secondary supporting
#      artifact (e.g. "qe2etest scenario S3 invoked POST + psql verify"). The
#      banlist only triggers if NO row's method column starts with /qe2etest.
# --------------------------------------------------------------------------
validate_qe2etest_evidence() {
  local file="$1"
  local label="${2:-evidence}"
  local diff_ref="${3:-}"
  local diff_cwd="${4:-}"

  if [ ! -s "$file" ]; then
    echo "${label}: ${file} missing or empty" >&2
    return 1
  fi

  # 2. Section heading (literal em-dash; reject naked "## Phase 3" or
  #    "## Phase 3 E2E" which were old conventions).
  if ! grep -qF '## Phase 3 — /qe2etest evidence' "$file" 2>/dev/null; then
    echo "${label}: missing literal heading \"## Phase 3 — /qe2etest evidence\" in ${file} (Phase-2-era headings rejected)" >&2
    return 1
  fi

  # Extract the Phase 3 section body for the next checks.
  local section
  section=$(awk '
    /^## Phase 3 — \/qe2etest evidence/ {flag=1; next}
    /^## / {flag=0}
    flag {print}
  ' "$file")

  if [ -z "$section" ]; then
    echo "${label}: ${file} has the Phase 3 heading but the section body is empty" >&2
    return 1
  fi

  # 3a. Check for the no-surface escape hatch FIRST. If present and valid,
  #     skip the PASS-verdict requirement. We require ≥10 chars of rationale
  #     to defeat one-word skips like "n/a" or "none".
  local no_surface
  no_surface=$(echo "$section" | grep -oE 'no qe2etest surface:[[:space:]]*[^\n]{10,}' | head -1)

  if [ -n "$no_surface" ]; then
    # Cross-check against diff if caller provided one.
    if [ -n "$diff_ref" ] && [ -n "$diff_cwd" ] && [ -d "$diff_cwd" ]; then
      local diff_paths
      diff_paths=$(cd "$diff_cwd" && git diff --name-only "$diff_ref" 2>/dev/null || true)
      if echo "$diff_paths" | grep -qE '\.(tsx|jsx)$|api/v1/.*\.py$|fetchJson\(|alembic/versions/.*\.py$'; then
        echo "${label}: claims \"no qe2etest surface\" but ${diff_ref} touches FastAPI/React/fetchJson/alembic — rationale is contradicted by diff. Run /qe2etest." >&2
        return 1
      fi
    fi
    return 0
  fi

  # 3b. Real evidence required. The section MUST contain /qe2etest invocation
  #     AND a PASS verdict (or explicit FAIL with fix commit — but FAIL alone
  #     is allowed only at scenario level, NOT as overall verdict).
  if ! echo "$section" | grep -qE '/qe2etest|Skill\(skill="?qe2etest"?\)'; then
    echo "${label}: Phase 3 section has no /qe2etest invocation line (neither slash command nor Skill tool call)" >&2
    return 1
  fi

  if ! echo "$section" | grep -qiE '^[^|]*PASS[^|]*$|\|[[:space:]]*PASS[[:space:]]*\|'; then
    echo "${label}: Phase 3 section has no PASS verdict line — /qe2etest did not run to completion" >&2
    return 1
  fi

  # 4. Banlist: Phase 3 section must not cite Phase 2 tooling as PRIMARY
  #    evidence. We check the method column heuristically: if the section
  #    contains rows with pytest/TestClient/psql/curl as the leading method
  #    AND zero rows starting with qe2etest, it's a banlist violation.
  local qe2etest_rows
  qe2etest_rows=$(echo "$section" | grep -cE '\|[[:space:]]*(/?qe2etest|qe2etest:)[[:space:]]*\|' || echo 0)

  local phase2_rows
  phase2_rows=$(echo "$section" | grep -cE '\|[[:space:]]*(pytest[[:space:]]|pytest::|TestClient|psql\b|^curl[[:space:]])' || echo 0)

  if [ "$qe2etest_rows" = "0" ] && [ "$phase2_rows" -gt 0 ]; then
    echo "${label}: Phase 3 section cites pytest/TestClient/psql/curl rows but ZERO /qe2etest rows — banlist violation (those are Phase 2 verification, not Phase 3)" >&2
    return 1
  fi

  return 0
}
