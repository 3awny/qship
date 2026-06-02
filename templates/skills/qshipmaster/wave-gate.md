# Wave Gate — Lightweight Per-Wave Review

This is the **default** per-wave review path for `/qshipmaster` (both `provider=claude` and `provider=codex`). It replaces the previous default of "skip per-wave Phase 2 entirely" and the older default of "run full Phase 2 per wave."

## Rationale

Full Phase 2 per wave is wasteful: 9+ parallel review agents (Step 8 reviewers + Step 9 bug hunters) get dispatched against a partial slice of the epic, and later waves rewrite the same files, so most of those findings get re-litigated at epic-end anyway. The cumulative deferred Phase 2 sees the **final shape** of the code and produces cleaner findings.

But "skip everything per wave" is too far the other way — if Wave 1 introduces a logic bug that Wave 2 builds on top of, the bug doesn't surface until epic-end, by which point waves 2+ may be wrong. We need a *cheap* gate that catches the kind of bug that **compounds across waves**, without the overhead of a full reviewer swarm.

Research basis:
- ["Sending the builder's reasoning to the validator poisons validator independence" — MindStudio](https://www.mindstudio.ai/blog/automated-code-review-multiple-ai-agents) → wave-gate hunters see ONLY the diff + touched files. No implementer rationale, no plan, no TRD context.
- ["Per-commit review's hidden cost is rebase/re-litigation" — Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/stacked-diffs) → defer opinion-graders (qcheck/qclean/qreuse/qcomponent) to epic-end on cumulative diff.
- ["Multi-model routing — expensive models only when justified" — Obvious Works](https://www.obviousworks.ch/en/token-optimization-saves-up-to-80-percent-llm-costs/) → wave-gate is capped at 2 hunters regardless of wave size; epic-end uses full T4 fan-out.
- ["Tight feedback loops on tests" — AddyOsmani](https://addyosmani.com/blog/ai-coding-workflow/) → typecheck + targeted tests per wave is the highest-value cheap signal.

## When this runs

After the wave merge into the consolidated epic branch succeeds (qshipmaster SKILL.md §Step 4) and BEFORE marking `state.json.waves[N].status = "shipped"`. The gate runs against the **wave's merged diff** (`git diff <prev_epic_tip>..HEAD`).

## Toggle precedence

The gate behavior is controlled by `QSHIP_PER_WAVE_REVIEW` (preferred) or the legacy `QSHIP_PER_WAVE_PHASE2` for back-compat:

| `QSHIP_PER_WAVE_REVIEW` | Behavior |
|---|---|
| `gate` (or unset — default) | Lightweight wave-gate below. **Recommended.** |
| `full` | Restore old behavior: full Phase 2 per wave (the §11.7 step inventory in SKILL.md §Step 5). |
| `none` | Skip everything per wave. Epic-end Phase 2 is the only safety net. Fastest but riskiest. |

Legacy `QSHIP_PER_WAVE_PHASE2=true` is honored as an alias for `QSHIP_PER_WAVE_REVIEW=full`. Legacy `QSHIP_PER_WAVE_PHASE2=false` is honored as an alias for `QSHIP_PER_WAVE_REVIEW=none`.

If both vars are set, `QSHIP_PER_WAVE_REVIEW` wins.

Always record the resolved mode in `state.json.waves[N].review_mode` so re-runs can detect drift.

## The four gate steps

Run in order. If any step fails, halt the wave and surface to the user — do NOT proceed to Wave N+1.

### Gate 1 — Migration chain check (mechanical, alembic only)

Trigger: wave's diff touches `*/alembic/versions/`.

Run `/qmigrationdevcheck` against the merged epic branch. If the chain is broken (orphan `down_revision`, missing parent, non-linear branch), HALT immediately. Migration chain breaks compound across waves — fixing later is "rewrite waves 2..N's migrations." Cheap to catch now.

If the diff does NOT touch `alembic/versions/`, record `Gate 1: [SKIPPED — no migration]` and continue.

### Gate 2 — Typecheck + targeted tests

Run only on **files the wave touched** (not the full repo). Cheap, deterministic, table stakes:

```bash
# Resolve touched files
TOUCHED_FILES=$(git diff <prev_epic_tip>..HEAD --name-only | grep -E '\.(py|tsx?|jsx?)$')

# Python: run pytest only on tests that import / sit near the touched files
PY_TOUCHED=$(echo "$TOUCHED_FILES" | grep '\.py$')
if [ -n "$PY_TOUCHED" ]; then
  pytest tests/ -v --tb=short -k "$(echo $PY_TOUCHED | xargs -n1 basename | sed 's/\.py$//' | paste -sd '|' -)"
fi

# JS/TS: typecheck + jest on touched files
if echo "$TOUCHED_FILES" | grep -qE '\.(tsx?|jsx?)$'; then
  npx tsc --noEmit
  npx jest --findRelatedTests $(echo "$TOUCHED_FILES" | grep -E '\.(tsx?|jsx?)$')
fi
```

If any check fails, dispatch a fix-only worker (same contract as SKILL.md §Step 5 — no `pytest.skip`, no `# noqa`, no stubs to fake green). Loop with `MAX_FIX_ITERS=3`. After 3, HALT.

The full-repo lint/format/test pass is **NOT** run per wave — it runs once at epic-end where the cumulative diff is final.

### Gate 3 — qbug-lite (2 hunters, isolated context)

Dispatch exactly two bug-hunter subagents in parallel against the wave's merged diff. **Both prompts include ONLY the diff and the list of touched files. No implementer rationale, no plan.md, no TRD context, no AGENTS.md inject.** Validator independence is the point — `qship-worker`'s implementation reasoning would bias the hunters toward confirming the implementer's mental model.

```
Agent A — logic-error-detector
Agent B — silent-failure-hunter
```

Why these two specifically:
- **logic-error-detector** catches off-by-one, inverted conditions, boolean mistakes — the failure mode most likely to make Wave N+1 build on a wrong assumption.
- **silent-failure-hunter** catches swallowed errors and masking fallbacks — the failure mode most likely to make epic-end E2E pass when the underlying behavior is broken.

The other Step 9 hunters (edge-case-hunter, data-flow-analyzer, race-condition-spotter, root-cause-tracer, security-scanner, dependency-checker) are deferred to epic-end. Their findings overlap heavily with the wave's editor and re-litigate at epic-end anyway.

Prompt skeleton for each hunter:

```
You are reviewing a wave-level diff inside an epic. Do not assume the implementer's mental model is correct. Look only at the merged diff and the touched files.

DIFF: `git diff <prev_epic_tip>..HEAD`
TOUCHED FILES: <list>
REPO: <repo>

Your role: <logic-error-detector | silent-failure-hunter>.

Report ONLY claims that meet all three:
1. Tied to a specific file:line in the merged diff
2. Triggered by realistic input (not theoretical)
3. Would survive into Wave N+1's working tree if not fixed now

For each claim, output:
- severity: Critical | High | Medium | Low
- file:line
- claim: one sentence
- minimal_repro: one paragraph

Skip style, naming, simplification, edge-case-after-the-edge-case, "could be cleaner" findings. Those are deferred to epic-end review.
```

### Gate 4 — qbcheck filter + Critical block

Pipe both hunters' claims through `qbcheck`. Validator independence remains intact because qbcheck doesn't see the hunters' reasoning chain — it re-traces each claim through the actual code path.

qbcheck's output:
- **Real Critical** → HALT the wave. Dispatch a fix-only worker (Claude, not Codex, even under `/qshipmaster provider=codex` — fixing review findings is exactly the kind of work Codex shouldn't do per qshipmaster SKILL.md §"Fix-worker dispatch stays in Claude"). Loop with `MAX_FIX_ITERS=3` per Critical. After 3, HALT and surface.
- **Real High / Medium / Low** → write to `{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-deferred-findings.md` and proceed. These get folded into the epic-end Phase 2 input so they're not lost.
- **False positive** → record and drop.

Record in `state.json.waves[N]`:
```json
{
  "review_mode": "gate",
  "gate_1_migration": "PASS|SKIPPED|FAIL",
  "gate_2_tests": "PASS|FAIL after N fix iters",
  "gate_3_hunters": { "raw": <int>, "after_qbcheck_critical": <int>, "after_qbcheck_high_plus": <int>, "false_positives": <int> },
  "gate_4_blocked_on_critical": true|false,
  "deferred_findings_file": "{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-deferred-findings.md"
}
```

## Epic-end Phase 2 — unchanged, plus consumes deferred findings

The epic-end Phase 2 (qshipmaster SKILL.md §Step 5's full inventory — 7.5, 8.3, 8.5.1, 8.6.5, 8.8, 9–10, 11, 11.5, 11.6, 11.7) runs once on the **cumulative merged diff** `git diff <state.json.base_branch>..HEAD` against the consolidated epic branch.

The only change at epic-end: when reading inputs for Step 8 / Step 9, **also load every `wave-<N>-deferred-findings.md` produced by the gates**. The reviewer/hunter agents see these as "prior wave-gate findings — re-evaluate against the final code state." Some will have been incidentally fixed by later waves and become non-issues. Some will still be live and get promoted into the epic-end finding set. Either way, no signal is lost.

## Expected cost reduction

Per-wave today (with full Phase 2 enabled): up to 9 Opus agents + qbcheck + fix-loop per wave.
Per-wave with this gate: 2 Opus hunters + 1 qbcheck + (occasional) fix-loop on Critical only.

For a 5-wave epic: ~5x reduction in per-wave review agent dispatches with no loss of cross-wave safety, because Gate 1 + Gate 2 + Gate 3 still catch the bugs that compound, and the deferred reviewers see the final shape at epic-end (cleaner findings, less re-litigation).

## What the gate explicitly does NOT do

- No `code-simplifier` per wave (deferred — simplifications get re-litigated as later waves edit the same code).
- No `qcheckt` / test-quality review per wave (deferred — wave's tests may be partial; final shape at epic-end).
- No `qcheck` / `qclean` / `qreuse` / `qcomponent` / `qdirectory` per wave (all deferred).
- No CLAUDE.md alignment audit per wave (deferred — same files get edited multiple times).
- No spec-compliance vs Jira AC per wave (deferred — wave doesn't ship a single ticket's worth of AC; epic does).
- No trailing-slash audit per wave (deferred — runs once at epic-end if any wave touched routes).
- **`/qe2etest` IS REQUIRED per wave** (see "Per-wave Phase 3 evidence contract" below) — and runs AGAIN once at epic-end against the cumulative merged diff. Pytest output is NOT a substitute.

## Per-wave Phase 3 evidence contract (HARD REQUIREMENT)

Pytest, integration tests (`TestClient(app).get(...)`), `psql` schema introspection, and raw `curl` one-offs are **NOT** sufficient Phase 3 evidence for a wave. They are Phase 2 verification.

Every wave whose merged diff touches **any** of:
- a FastAPI route (`@router.`, `APIRouter`)
- a React component (`*.tsx`, `*.jsx`, `dash_pages/`)
- an `fetchJson(` / cross-service HTTP caller
- an alembic migration that changes a column read by an endpoint

MUST run `/qe2etest` against the running local stack on the wave's merged branch tip BEFORE `state.json.waves[N].status` is allowed to flip to `"shipped"`. The wave-gate writes the output to `{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-qe2etest.log` and the wave evidence file (`wave-<N>-phase3-evidence.md`) MUST contain:

1. A `## Phase 3 — /qe2etest evidence` section (literal heading).
2. The `/qe2etest` invocation line and the resulting verdict line (`PASS` / `FAIL`) copied from `wave-<N>-qe2etest.log`.
3. A bullet list of the **scenarios actually exercised by /qe2etest** for this wave — each with the live artifact path (curl response txt, screenshot, psql verification block) under `{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-qe2etest-artifacts/`.

Acceptable skip clause (rare): `no qe2etest surface: <reason citing the diff>` — only valid if the wave's merged diff contains **zero** files matching the four bullets above. The supervisor's FINAL VERIFICATION cross-checks the rationale against `git diff <prev_epic_tip>..<wave_tip>` and rejects the wave if the diff contradicts the skip.

If `/qe2etest` fails on a wave, the wave-gate dispatches the same fix-only worker contract as test failures (no `pytest.skip`-equivalents, no test deletion, no stubbing) and re-runs. `MAX_FIX_ITERS=3`. After 3 failures, HALT — do not flip the wave to `"shipped"`.

## Epic-end Phase 3 — final /qe2etest pass (HARD REQUIREMENT)

After the last wave ships and BEFORE `qshipmaster-deliver.sh` is allowed to create PRs, the orchestrator runs `/qe2etest` ONE MORE TIME against the **cumulative epic branch** (`git diff <state.json.base_branch>..HEAD`). Output is written to `{{STATE_ROOT}}/epic-<EPIC>/epic-qe2etest.log`. PR creation is blocked until:

1. `epic-qe2etest.log` exists and contains a `PASS` verdict line, OR
2. `epic-qe2etest.log` contains an explicit `no qe2etest surface: <reason>` rationale that is consistent with the cumulative diff.

This catches the class of bugs only visible across multiple waves (e.g., wave-1 column rename + wave-4 caller update — neither wave alone fails E2E, but the wave-3 service in the middle is now broken on the integrated branch).
