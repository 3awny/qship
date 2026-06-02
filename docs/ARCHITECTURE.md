# Architecture

## Why qship exists

The default Claude Code experience is great for one-shot edits, but production work fails predictably in a few ways:

1. **Compaction drops the plan** — by Step 8 of a 15-step pipeline, the original task description has rolled out of context.
2. **"I'm done" hallucination** — the agent reports completion with Phase 3 (E2E) unrun.
3. **Soft rules get skipped under pressure** — "skipped TRD line 47 for time" appears casually mid-output.
4. **Stop-and-yield mid-task** — agent yields to user with progress files still showing PENDING rows.
5. **Sub-agents disagree with the orchestrator** — review surfaces 14 findings; only 6 get fixed; rest silently dropped.

qship solves each via a layered enforcement model.

## Three layers of enforcement

### Layer 1 — Soft rules (the skill markdown)

`SKILL.md` and `pipeline-steps.md` contain ~3500 lines of "you MUST" / "you MUST NOT" prose. These work most of the time because they're loaded at session start.

### Layer 2 — Hook gates (Bash, blocking)

When prose isn't enough, Bash hooks registered in `~/.claude/settings.json` block tool calls:

| Hook | Fires on | What it blocks |
|---|---|---|
| `require-phase3-evidence.sh` | PreToolUse(Bash) before `gh pr create`, `git push -- *PROJ-*`, `gh pr comment` | Phase 4 PR commands when `phase3-evidence.md` is missing, empty, or lacks HTTP/curl + "no network surface" rationale |
| `require-pre-pr-test-pass.sh` | PreToolUse(Bash) on `gh pr create` | Refuses if `phase4-tests-passed.<repo>.flag` is missing (Step 12.0) |
| `require-qe2etest-evidence.sh` | PreToolUse | Refuses if Step 11.6 didn't produce a `/qe2etest` log |
| `require-phase3-critic.sh` | PreToolUse | Validates the `qphase3critic` Sonnet pass on Phase 3 evidence |
| `require-pipeline-complete.sh` | Stop / SubagentStop | Refuses to terminate while any `phase2-progress.md` row is PENDING, `phase3-evidence.md` is empty, or `trd-coverage.json` has `passes: false` |
| `require-epic-scope-coverage.sh` | PreToolUse on epic-mode workers | Verifies the worker isn't touching files outside its assigned ticket scope |
| `block-pr-create-in-epic-mode.sh` | PreToolUse on `gh pr create` | Workers under EPIC_MODE=true cannot create individual PRs — the orchestrator creates the consolidated PR |

Hook returns `{"decision": "block", "reason": "..."}` to deterministically refuse the tool call. The agent then sees the rejection text and (per the prose contract) writes the missing artifact before retrying.

### Layer 3 — Outer persistence loop (`qship-persist.sh`)

For fully unattended runs, `qship-persist.sh` is the [ralph-pattern](https://ralphex.com/) wrapper:

```bash
bash ${SKILLS_ROOT}/qship/hooks/qship-persist.sh PROJ-42
```

It runs `claude --print "/qship PROJ-42"` in a loop until `claude --print "/qshipcheck PROJ-42"` returns `PASSED`. State lives in `${STATE_ROOT}/<TICKET>/` so each iteration resumes from where the previous one left off. Survives compaction, dropped connections, and rogue completion reports.

## How skills find your repos

qship uses **no fixed repo slots**. The configurator (`/qship:configure` or `bash setup.sh`) collects a flexible `repos[]` array — single repo, 2-repo split, 12-service monorepo are all valid — and writes the resolved list to `$SKILLS_ROOT/qship/repos.json` at install time.

**Single-repo aware skills** (qcheck, qclean, qbug, qcheckt, qcheckf, qcomponent, qreuse, qdirectory, qplan, qbcheck, qe2etest, qmanualt, qmemory) operate on `$(git rev-parse --show-toplevel)` — they never look at `repos.json`.

**Multi-repo aware skills** (qmigrationdevcheck, qshipmaster, qspinuplocal, qlocalclonedb) read `repos.json` at runtime and iterate over the entries flagged for their concern:

```bash
# qmigrationdevcheck — every repo with has_migrations=true
jq -r '.[] | select(.has_migrations==true) | .name' "$SKILLS_ROOT/qship/repos.json"

# qspinuplocal — every repo with runs_locally=true (in port order)
jq -r '.[] | select(.runs_locally==true) | "\(.port // 8000) \(.name)"' "$SKILLS_ROOT/qship/repos.json" | sort -n

# Resolve the user's primary repo (used by {{PRIMARY_REPO_NAME}} placeholder)
jq -r '(.[] | select(.is_primary==true) | .name) // .[0].name' "$SKILLS_ROOT/qship/repos.json"
```

A single-repo user gets a degenerate-but-correct check (one entry in the iteration). A multi-service monorepo user gets the full cross-repo coordination.

## Phase model

```text
Phase 1 (Build, ~5-30 min)
├── 1   Jira fetch
├── 2   Repo detection
├── 3   Pull latest develop
├── 4   Create branch
├── 4.1 Baseline test verify
├── 5   Write plan (superpowers:writing-plans)
├── 6   Plan review (qplan)
├── 7   TDD implement                                     ← provider=codex swap here
├── 7.3 Directory check (qdirectory)
└── 7.4 Clean defensive code (qclean)

   Phase 1 Gate — orchestrator audits Phase 1 output for stubs/TODOs

Phase 1.5 (TRD Mirror, ~5-10 min)
└── 7.45 Line-by-line spec vs code gap fix (Opus sub-agent)

Phase 2 (Review, ~15-45 min)
├── 7.5 Simplify (code-simplifier)                        ← reviewer=codex swap starts
├── 8.0 Complexity tier classification (T1-T4)
├── 8.1 Superpowers Code Reviewer  ┐
├── 8.2 Feature-Dev Code Reviewer  │  parallel fan-out scaled by tier
├── 8.3 Tests Reviewer (qcheckt)   │
├── 8.4 Spec Compliance Reviewer   ┘
├── 8.5.1 qmigrationdevcheck (alembic — opt-in)            ← always Claude
├── 8.6.5 qauthtrailingslash (FastAPI — opt-in)            ← always Claude
├── 9   Bug hunt fan-out (1-5 slots by tier)
├── 9.5 Dedupe + cross-agent convergence
├── 9.6 Top-K confidence-ranked filter
├── 10  qbcheck validation                                 ← reviewer=codex swap ends
├── 11  Fix issues                                         ← always Claude
├── 11.5 Verification Gate (fresh test + format + findings closure)
├── 11.6 /qe2etest smoke
└── 11.7 /qmemory capture

   Phase 2 Gate — /qshipphasecheck phase2

Phase 3 (Accept, ~30-90 min)
└── 14  /qmanualt full E2E with evidence
        ↳ orchestrator audits coverage, redispatches for gaps

   Phase 3 Gate — /qshipphasecheck phase3

Phase 4 (Deliver, ~10-30 min)
├── 12.0 Final test pass per repo (drops phase4-tests-passed.*.flag)
├── 12  gh pr create
├── 12.5 Watch CI (gh pr checks --watch)
├── 12.6 Auto-fix CI on failure (with forbidden-fix list)
├── 13  Final review (code-review:code-review)
└── 15  /qshipcheck — overall pipeline-complete assertion
```

## Epic mode (`qshipmaster`)

Given a Jira Epic, `qshipmaster`:

1. **Plans waves** — fetch children, parse Blocked-by graph, topological-sort into dependency waves.
2. **Per-wave parallel fan-out** — one `qship-persist.sh` per ticket per wave, in parallel.
3. **Wave merge** — additive merge of each completed wave into the consolidated epic branch.
4. **Wave-gate** — lightweight Phase 2 review (`qmigrationdevcheck` + targeted tests + 2 bug hunters + qbcheck) after each wave; blocks only on Critical.
5. **Epic-end Phase 2** — one full Phase 2 on the cumulative diff after the last wave.
6. **One PR per repo** — consolidated PR with `code-review:code-review` + cross-family critic.

State lives in `${STATE_ROOT}/epic-<EPIC>/state.json`; re-running resumes from the last completed step.

## State files (the "memory")

| File | Owned by | Purpose |
|---|---|---|
| `${STATE_ROOT}/<TICKET>/phase2-progress.md` | qship worker | Per-step DONE/PENDING table — `require-pipeline-complete.sh` reads this |
| `${STATE_ROOT}/<TICKET>/phase3-evidence.md` | qmanualt | API + UI evidence (curl logs, Playwright traces, rationales) |
| `${STATE_ROOT}/<TICKET>/trd-coverage.json` | Phase 1.5 sub-agent | Per-AC `passes: bool` matrix |
| `${STATE_ROOT}/<TICKET>/phase4-tests-passed.<repo>.flag` | Step 12.0 | Existence + freshness gates `gh pr create` |
| `${STATE_ROOT}/<TICKET>/pipeline-context.json` | Step 7 worker | API/UI classification of the diff |
| `${STATE_ROOT}/<TICKET>/phase2-findings.md` | Step 8.8 | Unified findings table consumed by Step 11 |
| `${STATE_ROOT}/<TICKET>/codex-runs/*.jsonl` | provider=codex | Raw JSONL event streams from `codex exec` |
| `${STATE_ROOT}/<TICKET>/codex-reviews/*.md` | reviewer=codex | Codex review outputs per slot |

Everything is on disk because the agent's context window can't be trusted across a 10-hour epic run.

## Inspirations + references

- [Ralph loop pattern](https://ralphex.com/) — outer persistence wrapper
- [PatchIsland multi-agent dedup](https://arxiv.org/html/2510.09721v3) — Step 9.5
- [CISC (Confidence-Improved Self-Consistency)](https://aclanthology.org/2025.findings-acl.1030.pdf) — Step 9.6 top-K filter
- [ClaudeFast routing](https://claudefa.st/blog/guide/agents/task-distribution) — §8.0 tier classification
- [GitHub Copilot Mar-2026 agentic rearchitecture](https://github.blog/changelog/2026-03-05-copilot-code-review-now-runs-on-an-agentic-architecture/) — mandatory codegraph step in qbug
- [Self-Healing Agent Pattern](https://dev.to/the_bookmaster/the-self-healing-agent-pattern-how-to-build-ai-systems-that-recover-from-failure-automatically-3945) — qshipmaster supervisor loop
