---
name: qshipmaster
description: Epic-level orchestrator for qship. Takes a Jira Epic ID, builds a topologically-sorted wave plan from its children, spawns one qship-persist.sh per ticket per wave in parallel, merges each wave into a consolidated epic branch, runs a lightweight wave-gate after each wave (migration check + targeted tests + 2 bug hunters + qbcheck, blocks only on Critical) and ONE full epic-level Phase 2 review after the last wave on the cumulative diff, and ships ONE consolidated PR per repo. Two engine knobs — `provider=claude|codex` chooses the Step 7 implementer (default Opus 4.7 1M, medium), and `reviewer=claude|codex` chooses the Phase 2 reviewer (default Claude). The diversified combo `provider=claude reviewer=codex` runs Opus implementing + gpt-5.5 high reviewing for different-family second opinion. Set `QSHIP_PER_WAVE_REVIEW=full` to restore full Phase 2 per wave, or `=none` to skip per-wave review entirely. Resumable, state-driven, idempotent.
disable-model-invocation: true
argument-hint: "<EPIC-ID> [provider=claude|codex] [reviewer=claude|codex]"
---

> **Issue source — `tracker = {{TRACKER_TYPE}}`** (chosen at onboarding). Follow the issue-source protocol in `$SKILLS_ROOT/qship/references/tracker-contract.md` — it defines, per tracker, how to FETCH / CHILDREN / CREATE / TRANSITION / READ-TRD. For `none`: treat `$ARGUMENTS` as the spec (pasted text or a local file path) and skip all tracker MCP calls.

# qshipmaster — Epic-level qship orchestrator

`qship` ships one ticket. `qshipmaster` ships an Epic.

This skill codifies the manual layer above `qship`: dependency-wave planning, per-wave parallel ticket execution, wave-level merging into a consolidated epic branch, wave-level Phase 2 review, and ONE consolidated PR per repo at the end.

> **Multi-repo contract:** The set of repos this orchestrator coordinates across is `$SKILLS_ROOT/qship/repos.json`. The "one PR per repo" pattern below means one PR per entry in that list (or a subset of entries actually touched by the epic). Single-repo users see exactly one PR per epic. Multi-service monorepo users see N PRs, one per affected repo. Resolve the list at orchestrator startup:
>
> ```bash
> ALL_REPOS=$(jq -r '.[].name' "$SKILLS_ROOT/qship/repos.json")
> ```

## ⛔ When this skill applies

Invoke `qshipmaster` when:
- The argument is a Jira **Epic** (`issuetype.name == "Epic"`).
- You want fully unattended end-to-end Epic delivery.

Do NOT invoke for:
- Standalone tickets (use `qship` directly).
- A single Story under an Epic (use `qship` directly — the parent SKILL.md §Epic-Mode hooks will keep the worker from opening a per-ticket PR).
- Re-running specific stages on an already-shipped Epic — read state.json directly and call the helper scripts manually.

## ⛔ Composition philosophy — DO NOT duplicate qship

`qshipmaster` is a **thin** orchestrator. It must:

1. **Compose** existing primitives, never re-implement them:
   - `qship-persist.sh` runs the per-ticket pipeline (don't reinvent it).
   - `qship-compute-context.sh` classifies the diff (don't reinvent it).
   - `require-phase3-evidence.sh` / `require-pipeline-complete.sh` enforce gates (don't bypass them).
   - `qshipcheck` decides per-ticket completion (don't second-guess it).
   - `code-review:code-review` is the final-PR review skill (don't reinvent it).

2. **Add only what's epic-specific**:
   - Wave plan construction from Jira parent/Blocked-by graph.
   - Per-wave fan-out + barrier (block until all wave tickets PASSED).
   - Wave merge into the consolidated epic branch with additive conflict resolution.
   - Wave-level (not per-ticket) Phase 2 lint/test pass on the merged diff.
   - Wave N+1 base-branch swap so worktrees see prior waves.
   - One consolidated PR per repo + final review.

3. **Persist everything** to `{{STATE_ROOT}}/epic-<EPIC>/state.json` so re-running the skill resumes from the last completed step.

## ⛔ Pre-flight gates

Before doing anything:

1. Verify the parent qship skill exists and the post-{{JIRA_PROJECT_KEY}}-EX01 patches are applied. The skill assumes:
   - `~/.claude/skills/qship/hooks/qship-persist.sh` honors `EPIC_MODE=true` (workers don't push, don't `gh pr create`).
   - `~/.claude/skills/qship/hooks/require-pipeline-complete.sh` recognizes wave-level Phase 3 evidence (`{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-phase3-evidence.md`) instead of demanding per-ticket evidence for every child.
   - `~/.claude/skills/qship/hooks/require-phase3-critic.sh` parses prose-wrapped JSON (the fallback chain documented in `{{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX01/post-epic-patches.md` §4).

   If any of these are missing, **HALT** and tell the user: *"qshipmaster requires post-{{JIRA_PROJECT_KEY}}-EX01 qship patches. See {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX01/post-epic-patches.md and apply patches 1, 3, 4, 5, 6 before re-running."*

2. Verify `pyenv` shims are first on PATH (post-patch §8). If `python3 --version` is < 3.10, prepend `{{USER_HOME}}/.pyenv/shims` and re-export PATH.

3. Verify `gh` is authenticated against `{{GH_HOST}}` (`gh auth status -h {{GH_HOST}}`).

4. **Browser MCP for Phase 3 — auto-launched by `qshipmaster-run.sh`, no user action.** Phase 3 sub-agents run inside `claude --print` subprocesses and cannot see the Claude in Chrome MCP (single-tenant native messaging host, bound to the user's interactive session). The orchestrator startup auto-launches a dedicated Chrome instance with `--remote-debugging-port=9222` and `--user-data-dir=$HOME/.cache/chrome-devtools-mcp-profile` if nothing is already listening on :9222. The user-scope MCP config at `~/.claude.json` declares `chrome-devtools-attach` pointing at `http://127.0.0.1:9222` — every spawned `claude --print` subprocess auto-loads it.

   **Why bother when DEV_MODE bypasses auth?** Phase 3 always runs the local stack with `DEV_MODE=true` (the external auth provider + cookies + admin role all bypassed — see memory `feedback_devmode_auth_layers.md`), so the Chrome profile's logged-in state is NOT what `chrome-devtools-attach` buys you over Playwright MCP. What it actually buys: (a) a window you can co-observe in real time as the subagent drives it, (b) persistent localStorage / IndexedDB across iterations, (c) ~3-5s saved per Phase 3 invocation by skipping Chromium cold start, (d) any browser extensions you've installed in the profile (React DevTools, etc.). For epics that are pure-backend (migration refactors, repository rewrites, anything with no UI surface), these advantages are marginal — set `QSHIP_SKIP_CHROME=true` and let Playwright handle it.

   Opt out with `QSHIP_SKIP_CHROME=true` if you need :9222 free for another tool or your epic doesn't touch UI. Phase 3 falls back to Playwright MCP (fresh Chromium, still works under DEV_MODE=true).

## How to invoke

Headless, fully unattended (from a terminal, NOT from inside Claude Code's Bash tool):

```bash
nohup bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-run.sh {{JIRA_PROJECT_KEY}}-EX01 \
  > {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX01/qshipmaster.log 2>&1 &
disown
```

Inside Claude Code (via `/qshipmaster {{JIRA_PROJECT_KEY}}-XXX [provider=claude|codex] [reviewer=claude|codex]`):

**Argument parsing.** Split `$ARGUMENTS` on whitespace. Extract any tokens matching `provider=(claude|codex)` or `reviewer=(claude|codex)` (case-insensitive on key, lowercase value) into `PROVIDER` / `REVIEWER` and remove them from the list. Reject duplicates or invalid values. The remaining single token is the `EPIC` id and must match `^[A-Z]+-\d+$`. Defaults: `PROVIDER=claude`, `REVIEWER=claude`.

**Provider selection — Step 7 implementer.**

- `PROVIDER=claude` (default): each per-ticket worker runs Step 7 as Claude TDD against `opus[1m]` at `medium` reasoning effort (override via `QSHIP_ITER_MODEL`/`QSHIP_ITER_EFFORT`).
- `PROVIDER=codex`: each per-ticket worker delegates Step 7's inner loop to `codex exec --model gpt-5.5 -c model_reasoning_effort=high` per task. Wave-gate, Phase 2 review (unless `REVIEWER=codex`), fix-worker dispatch, merge resolution, and final PR review remain in Claude — Codex never reviews its own work in a wave-gate. See [qship/step7-codex-override.md](../qship/step7-codex-override.md).

**Reviewer selection — Phase 2 reviewer (independent of `PROVIDER`).**

- `REVIEWER=claude` (default): Phase 2 (Steps 7.5, 8, 9, 10) runs as Claude Task subagents per the documented qship pipeline.
- `REVIEWER=codex`: inside each per-ticket worker, Step 6 Plan Review (`qplan`), 7.5, 8, 9, 10 delegate their analysis to `codex exec --model gpt-5.5 -c model_reasoning_effort=high` per slot. Step 11 (Fix), 11.5 (Verification), 11.6 (`/qe2etest`), 11.7 (`/qmemory`) and the **wave-gate + epic-end Phase 2 review** stay in Claude (the wave-gate's value is precisely the diversity-of-model second opinion — running both layers on Codex collapses that). See [qship/reviewer-codex-override.md](../qship/reviewer-codex-override.md).
- Recommended combo for epics where you want diversity-of-model coverage without giving up {{COMPANY_SLUG}} implementation taste: `provider=claude reviewer=codex`. Avoid `provider=codex reviewer=codex` — same-family review on same-family code collapses the signal.

**Skill access for Codex.** Codex sees the same skill catalog as Claude via `~/.codex/skills/<name>` symlinks pointing at `~/.agent-skills/<name>` (same target `~/.claude/skills` points at — single source of truth, see `~/.agent-skills/README.md`). Per the [Codex Agent Skills docs](https://developers.openai.com/codex/skills), Codex reads SKILL.md frontmatter the same way Claude does, so `qcheckt`, `qclean`, `qbug`, `qbcheck`, etc. are reachable via `/skills` or `$<skill-name>` mentions. Run `sync-agent-skills` after creating or deleting any skill to refresh the symlink farm.

When `PROVIDER=codex`, additionally run the [`/qship` Provider pre-flight](../qship/SKILL.md#provider-selection--claude-default-vs-codex) (codex CLI installed, authenticated, gpt-5.5 reachable) AND scan all epic children for carve-out triggers (`alembic`, `migration`, `enum`, `RLS`, `tenant`, `cross-repo`, `auth middleware`). If any child matches, surface options:
> "Epic <ID> has N children that touch sensitive areas. Options:
>  a) Rerun without `provider=codex` (safest — Claude implements everything).
>  b) Split: run the codex-safe children via `/qshipmaster <EPIC> provider=codex` and the sensitive children manually via `/qship <TICKET>`.
>  c) Proceed anyway — codex's per-task fallback (Claude takes over after 2 failures) handles the bumps, but expect slower throughput."

Default to (a) unless the user explicitly picks (b) or (c). Don't silently assume.

**The model MUST launch this via the Bash tool with `run_in_background: true`.** Compose the env-var prefix based on `PROVIDER` and `REVIEWER` (omit either block entirely when its value is `claude`):

```
ENV_PREFIX=""
if [ "$PROVIDER" = "codex" ]; then
  ENV_PREFIX+="QSHIP_IMPL_ENGINE=codex QSHIP_CODEX_MODEL=gpt-5.5 QSHIP_CODEX_EFFORT=${QSHIP_CODEX_EFFORT:-high} "
fi
if [ "$REVIEWER" = "codex" ]; then
  ENV_PREFIX+="QSHIP_REVIEW_ENGINE=codex QSHIP_CODEX_REVIEWER_MODEL=gpt-5.5 QSHIP_CODEX_REVIEWER_EFFORT=${QSHIP_CODEX_REVIEWER_EFFORT:-high} "
fi

Bash(
  command: "mkdir -p {{STATE_ROOT}}/epic-<EPIC>/logs && ${ENV_PREFIX}nohup bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-run.sh <EPIC> > {{STATE_ROOT}}/epic-<EPIC>/qshipmaster.log 2>&1 & disown; echo started",
  run_in_background: true,
  description: "Launch qshipmaster orchestrator detached"
)
```

Concrete examples:

```bash
# /qshipmaster {{JIRA_PROJECT_KEY}}-EX01                           — all Claude (default)
nohup bash …/qshipmaster-run.sh {{JIRA_PROJECT_KEY}}-EX01 …

# /qshipmaster {{JIRA_PROJECT_KEY}}-EX01 provider=codex            — codex implements
QSHIP_IMPL_ENGINE=codex QSHIP_CODEX_MODEL=gpt-5.5 QSHIP_CODEX_EFFORT=high nohup …

# /qshipmaster {{JIRA_PROJECT_KEY}}-EX01 reviewer=codex            — claude implements, codex reviews Phase 2
QSHIP_REVIEW_ENGINE=codex QSHIP_CODEX_REVIEWER_MODEL=gpt-5.5 QSHIP_CODEX_REVIEWER_EFFORT=high nohup …

# /qshipmaster {{JIRA_PROJECT_KEY}}-EX01 provider=codex reviewer=codex     — discouraged (see "Reviewer selection")
QSHIP_IMPL_ENGINE=codex … QSHIP_REVIEW_ENGINE=codex … nohup …
```

The env vars travel through `nohup` → `qshipmaster-run.sh` → its inner `claude --print` worker invocations → into each `qship-persist.sh` child. `~/.claude/agents/qship-worker.md` §Step 7 reads `$QSHIP_IMPL_ENGINE` (routes to `~/.claude/skills/qship/step7-codex-override.md`), and the reviewer-engine block reads `$QSHIP_REVIEW_ENGINE` (routes Steps 6, 7.5, 8, 9, 10 to `~/.claude/skills/qship/reviewer-codex-override.md`). No change to the shell scripts is required — environment inheritance handles it.

Why this matters: qshipmaster orchestrates 6-wave epics over ~10-15 hours. Foreground execution pins the entire user session for that duration — the Bash tool's 10-minute timeout fires before the first wave's worker finishes, and even if a hook bumps the timeout, the user can't reclaim their conversation slot. The first qshipmaster v2 deployment shipped without this rule and bit {{JIRA_PROJECT_KEY}}-EX07's first launch in May 2026 — see [qship memory: feedback_qshipmaster_must_background](file://{{USER_HOME}}/.claude/projects/-Users-{{LOCAL_DB_USER}}-work-{{GH_ORG}}-{{COMPANY_SLUG}}-codebase/memory/feedback_qshipmaster_must_background.md).

After launch, the model polls `{{STATE_ROOT}}/epic-<EPIC>/state.json` periodically (via `/loop` or `ScheduleWakeup`) for `status: shipped` or `status: blocked` — never via `tail -f` or a blocking wait.

## Model + effort env vars — single reference

Every `claude --print` and `codex exec` dispatch in qship / qshipmaster can be tuned via env vars. The defaults below were chosen to follow one rule of thumb: **plan/design = `xhigh`, review = `high`, mechanical work = `medium`, narrow text ops = the model's own default**. Higher leverage on a single decision → stronger model + more reasoning depth.

### Per-ticket pipeline (qship — per-ticket worker)

| Role | Site | Model var | Default model | Effort var | Default effort |
|---|---|---|---|---|---|
| Step 5 — Plan writing (`superpowers:writing-plans` subprocess) | `qship-worker.md` §5 | `QSHIP_PLAN_MODEL` | `opus[1m]` | `QSHIP_PLAN_EFFORT` | `xhigh` |
| Step 6 — Plan review (`qplan` subprocess, when `reviewer=claude`) | `qship-worker.md` §6 | `QSHIP_PLAN_REVIEW_MODEL` | `opus[1m]` | `QSHIP_PLAN_REVIEW_EFFORT` | `high` |
| Steps 7–7.5 — Implementation / cleanup / simplify (worker iter loop) | `qship-persist.sh:162-163` | `QSHIP_ITER_MODEL` | `opus[1m]` | `QSHIP_ITER_EFFORT` | `medium` |
| `/qshipcheck` verdict reader | `qship-persist.sh:177` | `QSHIP_CHECK_MODEL` | `claude-haiku-4-5-20251001` | n/a | n/a |
| Step 7 — Implementation **with `provider=codex`** (Codex CLI subprocess per task) | `step7-codex-override.md` | `QSHIP_CODEX_MODEL` | `gpt-5.5` | `QSHIP_CODEX_EFFORT` | `high` |
| Phase 2 review **with `reviewer=codex`** (Steps 6 plan-review, 7.5 simplify, 8 reviewers, 9 hunters, 10 qbcheck via Codex) | `reviewer-codex-override.md` | `QSHIP_CODEX_REVIEWER_MODEL` | `gpt-5.5` | `QSHIP_CODEX_REVIEWER_EFFORT` | `high` |

### Epic pipeline (qshipmaster)

| Role | Site | Model var | Default model | Effort var | Default effort |
|---|---|---|---|---|---|
| Wave-plan construction (Jira fetch + DAG build) | `qshipmaster-plan.sh:52` | `QSHIP_PLAN_MODEL`* | `opus[1m]` | `QSHIP_PLAN_EFFORT`* | `xhigh` |
| Wave-batch + epic Phase 2 review (consolidated review across merged tickets) | `qshipmaster-run.sh:443` | `QSHIP_PHASE2_REVIEW_MODEL` | `opus[1m]` | `QSHIP_PHASE2_REVIEW_EFFORT` | `high` |
| Phase 2 fix iterations (apply MUST-FIX findings, black/isort/flake8/pytest) | `qshipmaster-run.sh:642, 734` | `QSHIP_FIX_MODEL` | `opus[1m]` | `QSHIP_FIX_EFFORT` | `medium` |
| Epic-end Phase 3 scenario matrix design (`superpowers:brainstorming`) | `qshipmaster-deliver.sh:321` | `QSHIP_EPIC_PHASE3_DESIGN_MODEL` | `opus[1m]` | `QSHIP_EPIC_PHASE3_DESIGN_EFFORT` | `xhigh` |
| Epic-end Phase 3 execution (live `/qe2etest` against scenario matrix) | `qshipmaster-deliver.sh:359` | `QSHIP_EPIC_PHASE3_EXEC_MODEL` | `opus[1m]` | `QSHIP_EPIC_PHASE3_EXEC_EFFORT` | `high` |
| Step 13 PR primary review (`code-review:code-review` skill on the consolidated PR) | `qshipmaster-deliver.sh:161` | `QSHIP_PR_REVIEW_MODEL` | `opus[1m]` | `QSHIP_PR_REVIEW_EFFORT` | `high` |
| Step 13 PR external-family critic (engine selection) | `qshipmaster-deliver.sh:165` | `QSHIP_CRITIC_ENGINE` | (gated by `QSHIP_REVIEW_ENGINE`) | — | — |
| Step 13 critic — codex branch (only when `reviewer=codex` opted in) | `qshipmaster-deliver.sh:230` | `QSHIP_CODEX_CRITIC_MODEL` | `gpt-5.5` | `QSHIP_CODEX_CRITIC_EFFORT` | `high` |
| Non-additive merge auto-resolver | `qshipmaster-merge-wave.sh:196, 205` | (hardcoded) | `sonnet` | (none) | (default) |
| Cross-epic memory extractor (3-line `ROOT_CAUSE`/`FIX`/`RULE` distillation) | `qshipmaster-learn.sh:46` | (hardcoded) | `haiku` | (none) | (default) |

*`QSHIP_PLAN_MODEL` / `QSHIP_PLAN_EFFORT` are shared between the per-ticket Step 5 plan subprocess (worker side) and the qshipmaster wave-plan construction (orchestrator side). Same operation type (planning), same defaults, one set of knobs.

### Engine-selection flags (boolean opt-ins, not model/effort)

| Flag | Default | Effect |
|---|---|---|
| `QSHIP_IMPL_ENGINE=codex` | unset | Step 7 implementation routes to `codex exec` instead of Claude TDD. Set automatically when user passes `provider=codex` to `/qship` or `/qshipmaster`. |
| `QSHIP_REVIEW_ENGINE=codex` | unset | Phase 2 review (Steps 6, 7.5, 8, 9, 10) routes to `codex exec`. Set automatically when user passes `reviewer=codex`. ALSO gates the Step 13 critic to use codex. |
| `QSHIP_CRITIC_ENGINE={codex,sonnet}` | unset | Forces the Step 13 critic engine regardless of `QSHIP_REVIEW_ENGINE`. Use to explicitly pin one engine for the critic step. |

### When to override

- **Cost-conscious dev runs:** set `QSHIP_ITER_EFFORT=low` and `QSHIP_PLAN_EFFORT=high` (down from xhigh) for cheap iteration. Bump back to defaults before the run that actually ships.
- **Particularly twisted epic dependency graph:** keep `QSHIP_PLAN_EFFORT=xhigh` (default) but consider `QSHIP_PHASE2_REVIEW_EFFORT=xhigh` if early waves shipped subtle cross-wave bugs.
- **Codex CLI unavailable but you want different-family review:** keep the defaults — sonnet is the fallback for both Phase 2 review and the Step 13 critic.

## Invariants (formal, hook-enforceable)

These are the contract-level invariants the supervisor and orchestrator both enforce. Encoded here so future changes to either layer can grep-verify they're not silently relaxed. Each invariant maps to a concrete check; the FINAL VERIFICATION step (supervisor step 7) re-checks all of them on `status: shipped`.

| # | Invariant | Concrete check |
|---|---|---|
| I1 | Wave N+1 MUST NOT spawn workers until Wave N's `wave-N-phase23-evidence.md` exists AND contains all 4 marker words (qsimplify, qcheck, qbug, qbcheck) AND contains a `## Phase 3 — /qe2etest evidence` section with a `/qe2etest` PASS verdict line copied from `wave-<N>-qe2etest.log` (or an explicit `no qe2etest surface:` rationale consistent with the merged diff). Pytest tallies, `TestClient` output, raw curl one-offs, and `psql` schema dumps are NOT acceptable substitutes. | `grep -q` for `/qe2etest` and PASS verdict in the evidence file; orchestrator enforces via `require-pipeline-complete.sh`. Supervisor verifies on each poll that the *latest shipped* wave's evidence still satisfies the invariant (catches retroactive edits). |
| I2 | Every wave that touches `alembic/versions/` MUST have a single linear migration chain — no orphan heads, no diamond merges | `alembic heads` returns exactly 1 line per repo. Run after each wave merge. |
| I3 | No commit on `<epic_branch>` may contain placeholder fixes: `pytest.skip`, `@pytest.mark.skip`, `@pytest.mark.xfail`, `assert True\s*$`, `try:\s*\n\s*.*\n\s*except.*:\s*\n\s*pass`, `# noqa`, `# type: ignore` added (not pre-existing) | `git log -p develop..<epic_branch>` grepped against the banlist. Supervisor runs once at FINAL VERIFICATION. |
| I4 | Recovery rate ≥ drift rate (ABC Drift Bounds Theorem: γ ≥ α) | Per-epic: count of supervisor HEAL actions / count of unrecovered escalations ≥ 1. If escalations outnumber heals across the epic, drift is winning — flag the epic in AGENTS.md. |
| I5 | Every CRITICAL/HIGH finding in any `phase2-findings.md` MUST have a corresponding fix commit on `<epic_branch>` OR an explicit deferred-to-epic-end entry in `wave-N-deferred-findings.md` | `grep -E "CRITICAL\|HIGH" phase2-findings.md` count must equal (commits referencing the finding ID) + (deferred-findings entries). Supervisor checks on FINAL VERIFICATION. |
| I6 | `state.json.pr_url_per_repo` must be populated for every repo in `state.json.repos` before `status` flips to "shipped" | Direct jq check. Already in FINAL VERIFICATION. |
| I7 | No two consecutive waves may both have `no ui surface` notes if either wave touched a React component, FastAPI route, or `fetchJson` call | grep the merged diff per wave for `.tsx`, `.jsx`, `@router.`, `fetchJson(` — if any match, that wave MUST have Phase 3 evidence with concrete artifacts, not a no-ui-surface skip. |
| I8 | Final epic-end `/qe2etest` MUST run against the cumulative epic branch BEFORE `qshipmaster-deliver.sh` creates PRs. `{{STATE_ROOT}}/epic-<EPIC>/epic-qe2etest.log` must exist with a PASS verdict, OR contain a `no qe2etest surface: <reason>` rationale consistent with `git diff <base>..HEAD`. Pytest passing on the integrated branch is NOT a substitute — wave-isolated pytest cannot detect cross-wave integration drift (e.g., wave-1 schema rename × wave-4 caller update). | `grep -E '^PASS\|no qe2etest surface:' epic-qe2etest.log`. Supervisor blocks `status: shipped` until present. Hook `require-phase3-evidence.sh` greps for this on `gh pr create` in epic mode. |

Invariants are sorted by enforcement priority: I1-I3 are hard pre-conditions (block subsequent work), I4-I5 are post-conditions (block shipped status), I6-I7 are completeness/anti-skip guards.

## Re-run on Critical: probabilistic compliance for wave-batch reviews

Single-pass review accepts LLM non-determinism — a flaky finding might be missed, a real bug might be falsely demoted. ABC framework recommends p-delta-k compliance: re-run the high-risk step and accept only if N independent runs agree.

The orchestrator runs this automatically on wave-batch reviews:

- After the initial review, parse `wave-N-phase23-evidence.md` for the qbcheck verdict table.
- If qbcheck kept ≥2 CRITICAL findings AS MUST FIX (not demoted), dispatch a **second independent review claude** with a different temperature/seed prompt to re-evaluate the same diff.
- Accept the finding set only if both runs agree on at least the CRITICAL items. Disagreement → keep the union (more conservative), AND add a `## Re-run delta` section to the evidence file listing each finding where the two runs differed.
- 0-1 CRITICAL findings → no re-run (single-pass is fine).
- Cost: ~30-40 min extra wall time per affected wave. Worth it for CRITICAL-rich diffs; skipped for clean ones.

This is encoded in the wave-batch prompt's REQUIRED EVIDENCE section. The supervisor verifies the re-run actually happened by checking `wave-N-rerun-decision.txt` exists and matches the qbcheck count.

## Async-notification tier (non-blocking signals)

Three tiers of supervisor response:
1. **Auto-handle** — fix and continue (default for the taxonomy in the supervisor recipe).
2. **Async-notify** — drop a one-line entry in `{{STATE_ROOT}}/epic-<EPIC>/inbox/` with timestamp + short reason, and CONTINUE. User reviews retroactively on next session.
3. **Escalate (blocking)** — pause the loop, message the user, wait for response.

The inbox tier exists for "I'd want to know about this but it doesn't block progress" — e.g.:
- Auto-resolver succeeded on a merge conflict but the resolution looks heuristic (>20 lines changed).
- A worker hit a transient claude-print 502 and retried successfully.
- A finding was demoted by qbcheck but the original hunter agent had high confidence.
- AGENTS.md grew by >5 entries this epic (indicates many failures, even if all recovered).

Inbox file format: `{{STATE_ROOT}}/epic-<EPIC>/inbox/<UTC-iso>-<short-tag>.md`. Supervisor never modifies existing entries (append-only). User's next session can `ls {{STATE_ROOT}}/epic-<EPIC>/inbox/` to see them.

## Supervisor loop — auto-intervention recipe

**The model MUST schedule a `ScheduleWakeup` (270s — stays inside the prompt-cache TTL) immediately after the launch Bash call, with the supervisor self-prompt below. The loop continues firing until `status` is `shipped` or the supervisor escalates to the user.** This is non-negotiable: `qshipmaster` runs unattended for 10-15h and the orchestrator's built-in stall-detector + per-iter timeout cover only ~70% of failure modes. The supervisor loop catches the rest.

Architecture follows the standard self-healing agent pattern — **Detect → Classify → Heal → Verify** ([dev.to/the_bookmaster](https://dev.to/the_bookmaster/the-self-healing-agent-pattern-how-to-build-ai-systems-that-recover-from-failure-automatically-3945), [Latitude failure-mode taxonomy](https://latitude.so/blog/ai-agent-failure-detection-guide)) — with **progressive response** (self-correct → fallback → degrade → escalate) and an **explicit failure taxonomy** so each failure class gets a different recovery strategy ([Heavy Thought Labs error taxonomy](https://heavythoughtcloud.com/knowledge/error-taxonomy-for-ai-systems)). Auto-handled classes never bug the user; only judgment-required classes escalate.

### Supervisor self-prompt (use verbatim — substitute the literal EPIC id)

```
qshipmaster supervisor check for <EPIC>:

1. EXIT CONDITIONS (highest priority — check first):
   - jq -r '.status' {{STATE_ROOT}}/epic-<EPIC>/state.json
     - == "shipped" → **run FINAL VERIFICATION (step 7) before stopping.** Only STOP the loop if every contract check passes; otherwise escalate.
     - == "blocked" with .error matching /401|auth|credentials/i → ESCALATE: ask user to re-auth (claude /login), STOP looping until they reply
     - == "blocked" with any other .error → run CLASSIFY step on the error string, then HEAL if recipe matches; otherwise ESCALATE with the error and let user decide

2. DETECT — collect signals:
   - state.status, state.error, current wave number + status
   - pgrep -lf "qshipmaster-run.sh <EPIC>" — is orchestrator alive?
   - pgrep -lf "claude --print" — list all in-flight workers with pid/etime/pcpu
   - For each in-flight claude: check recent file mods in its worktree (find {{STATE_ROOT}}/worktrees/<TICKET> -mmin -30 -type f ! -path '*/.git/*' | head -1)
   - tail -10 {{STATE_ROOT}}/epic-<EPIC>/qshipmaster.log
   - Read the relevant persist log if a wave is stuck

3. CLASSIFY + HEAL — apply this taxonomy (auto-handled unless marked ESCALATE):

   | Symptom | Recovery |
   |---|---|
   | Hung per-iter claude — pcpu < 0.5% AND no worktree file mods in 30 min | `kill <pid>`; persist will retry iter N+1 automatically. Confirm next poll shows new claude pid. |
   | Hung wave-batch review — review claude pcpu < 0.5% AND no orchestrator log line in 30 min | `kill <pid>`; orchestrator's `\|\| true` continues to next repo or wave. |
   | Hung Phase-3 (heartbeat stale) — `find {{STATE_ROOT}}/epic-<EPIC>/wave-<N>-heartbeat.txt -mmin +15` returns the file | Same as above (`kill` the review claude). Heartbeat staleness is a stronger signal than CPU% because Phase 3 work is mostly waiting on Playwright/local-server I/O — low CPU is expected, no heartbeat is not. |
   | Orchestrator dead, state.status=in_flight | Relaunch: `nohup bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-run.sh <EPIC> >> {{STATE_ROOT}}/epic-<EPIC>/qshipmaster.log 2>&1 & disown` |
   | Stall-detector false-positive — state.error mentions "stalled" but the ticket's PASSED flag landed within 5 min after the HALT | `jq` clear .error, set .status="in_flight", set the stalled wave's .status back to "in_flight", then relaunch orchestrator with `STALL_POLLS=120` env to bump the threshold. |
   | Merge conflict — orchestrator dispatched auto-resolver, resolver failed (look for "auto-resolver failed" in log) | Inspect `git diff --name-only --diff-filter=U` in the repo. If conflicts are <30 lines AND additive-merge policy applies (exports, registrations, package init), resolve inline with Edit and `git commit -am "resolve conflict"`. Otherwise ESCALATE with the file list. |
   | Ticket GAVE UP after 5 iters — read `{{STATE_ROOT}}/worktrees/<TICKET>/iter-failure-log.md` for cause classification | If cause is transient (flaky network, MCP hiccup, single failed pytest that passes locally): wipe persist log + iter logs, reset that ticket's row in tickets_pending, relaunch orchestrator. Allow ONE retry round only. If 5 more iters fail, ESCALATE. If cause is logic bug or spec issue, ESCALATE — the model is the wrong fixer. |
   | Auth 401 on every iter (iter-*.log contains "Invalid authentication credentials") | ESCALATE — only the user can refresh credentials. |
   | Migration chain conflict — wave-N-phase23-evidence.md says "migration chain broken" or "multiple alembic heads" | Run `/qmigrationdevcheck` in the affected repo, apply its prescribed fix (usually one-line down_revision edit), commit, then relaunch orchestrator. |
   | Wave-end Phase 2 lint/test fail with MUST-FIX unresolved | Dispatch a fix-only worker (`opus[1m]` medium by default — `QSHIP_FIX_MODEL`/`QSHIP_FIX_EFFORT` override; matches the implementation default since fix work often spans the same cross-file invariants). The wave-end Phase 2 *review* itself that produced these MUST-FIX findings runs at `QSHIP_PHASE2_REVIEW_MODEL`/`QSHIP_PHASE2_REVIEW_EFFORT` (`opus[1m]` high), and the later epic-end Phase 3 scenario design / execution use `QSHIP_EPIC_PHASE3_DESIGN_*` (`opus[1m]` xhigh) and `QSHIP_EPIC_PHASE3_EXEC_*` (`opus[1m]` high). EPIC_MODE=true, scoped to the wave's merged diff. If the fix worker returns non-zero or `wave-N-blocked.md` exists, ESCALATE. |
   | Environment blocker — log says "{{PRIMARY_REPO_NAME}} unavailable" / "DB connection refused" / "the external auth provider 500" | ESCALATE — out of scope for code changes. |
   | Anything else not in this table | ESCALATE with full context (state.error, last 20 log lines, the relevant persist log tail). |

4. VERIFY — after any HEAL action, immediately re-run DETECT and confirm:
   - The symptom is gone (new claude pid, orchestrator alive, state.error cleared, etc.)
   - No new error introduced
   If HEAL didn't take effect, ESCALATE rather than re-attempting blindly (Huntley's fix_plan-repetitive guard).

5. SCHEDULE NEXT — if no EXIT condition fired, call ScheduleWakeup with delaySeconds=270 and this same prompt. Always 270s (cache-warm), never 300+ (cache miss).

6. CAPTURE LEARNINGS — if HEAL resolved a non-trivial block, append a one-line entry to ~/.claude/skills/qshipmaster/AGENTS.md (auto-injected into worker prompts on next run): ROOT_CAUSE / FIX / RULE. Same format as qshipmaster-learn.sh.

7. FINAL VERIFICATION (only when state.status flipped to "shipped" — supervisor MUST run this before stopping the loop and reporting success to the user). The orchestrator can write "shipped" while silently skipping a contract requirement (e.g. the wave-2 phase23-evidence.md missing Phase 3 content in the {{JIRA_PROJECT_KEY}}-EX07 run was logged as WARN, not error). Treat "shipped" as a *claim* the supervisor must validate. For each wave 1..N and each repo in state.json.repos, verify all of the following — if ANY check fails, ESCALATE with the specific failing check (do NOT auto-fix; "shipped" is past the point where auto-heal is safe):

   **Per-wave evidence file** (`{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-phase23-evidence.md`):
   - Exists and is non-empty.
   - Contains all four Phase 2 marker words: `qsimplify`, `qcheck`, `qbug`, `qbcheck` (the orchestrator's require-pipeline-complete.sh hook greps for these — missing markers = fake-shipped).
   - Contains a `## Phase 3 — /qe2etest evidence` section with a `/qe2etest` invocation line + a `PASS` verdict copied from `{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-qe2etest.log`, OR a literal `no qe2etest surface: <reason>` rationale (the supervisor cross-checks the rationale against `git diff <prev_epic_tip>..<wave_tip>` and rejects if the diff touches FastAPI routes / `*.tsx` / `*.jsx` / `fetchJson(` / endpoint-reachable alembic columns).
   - Pytest counts, `TestClient` output, raw curl one-offs, and `psql` dumps are explicitly NOT acceptable as Phase 3 evidence — they are Phase 2 verification artifacts. If the wave evidence cites those as Phase 3, the supervisor escalates regardless of `status: shipped`.

   **Epic-end /qe2etest** (`{{STATE_ROOT}}/epic-<EPIC>/epic-qe2etest.log`):
   - Exists and contains a `PASS` verdict line, OR a `no qe2etest surface: <reason>` rationale consistent with `git diff <state.json.base_branch>..HEAD`.
   - Mtime is newer than the last wave's `shipped` timestamp in `state.json` (proves the epic-end run happened against the integrated branch, not stale from an earlier wave).

   **Per-repo PR** (gh-cli check per repo in `state.json.pr_url_per_repo`):
   - PR URL exists in state.json.
   - `gh pr view <url> --json state,reviews,comments` shows: state == OPEN (or MERGED if user merged manually), at least one review comment from `code-review:code-review` skill, and a `## Sonnet critic` comment from the external-model critic step.
   - `gh pr diff <url>` returns non-empty (the consolidated branch actually has commits).

   **Cross-epic memory hygiene**:
   - `~/.claude/skills/qshipmaster/AGENTS.md` mtime is newer than epic-start time IF any Phase 2 fix iterations ran (memory was captured). Stale AGENTS.md after fix iters = qshipmaster-learn.sh was skipped.

   **State sanity**:
   - `state.json.waves[].status` is "shipped" for every wave (not "merged" — "merged" means the merge happened but batch review didn't complete).
   - `state.json.pr_url_per_repo` is populated for every repo in `state.json.repos`.

   If all checks pass: report PR URLs + per-wave summary to user, STOP looping. If any fail: surface the exact failing check + the specific file/PR path + your recommendation (fix the gap by hand, then re-run that single step, OR accept the gap with explicit user sign-off).

8. SELF-IMPROVE — after each HEAL action, evaluate whether the underlying skill/pipeline should be patched so the same failure class cannot recur. The threshold for self-modification is high on purpose: single failures might be transient (network blip, model variance), only RECURRING failures warrant a code-level fix.

   **Trigger** (all three must hold):
   - The failure class matched a row in the supervisor taxonomy (i.e. it's a known class, not novel).
   - The same failure class has fired ≥2 times in the current epic OR ≥3 times across the last 30 days (count by `grep -c "key: <class>" ~/.claude/skills/qshipmaster/AGENTS.md`).
   - The HEAL action was reactive (kill + relaunch, env var override, etc.) — i.e. a root-cause fix to the skill could replace it.

   **Procedure**:
   a. Write a one-paragraph diagnosis to `{{STATE_ROOT}}/epic-<EPIC>/inbox/self-improve-<class>-<ts>.md` with: SYMPTOM (observable behaviour), ROOT_CAUSE (your best hypothesis), EVIDENCE (log excerpts, file mtimes, CPU/file-mod fingerprints), HEAL_APPLIED (what you did reactively), RECOMMENDED_PATCH (free-form: which file should change and how).
   b. Invoke `bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-self-improve.sh <EPIC> <FAILURE_CLASS_KEY> <DIAGNOSIS_MD_PATH>`. The script handles research, confidence check, sandbox enforcement, backup, patch, syntax check, and AGENTS.md logging.
   c. Exit code interpretation:
      - `0` → patch applied (or already-applied marker found); future runs benefit, current run continues normally.
      - `1` → research inconclusive or confidence < 75 → ESCALATE to user. Drop a note in the inbox with the proposal path; do not retry until user reviews.
      - `2` → patch failed sandbox / syntax / dry-run check → REJECT silently, drop an inbox note; continue the run reactively without the patch.
      - `3` → invocation error in the wrapper itself → log and continue.
   d. The wrapper is idempotent (marker comments) — calling it on already-patched issues is a no-op.

   **What may be patched**:
   - Timeout values (raise/lower), retry counts, env var defaults, stall thresholds.
   - New prompt directives in worker autonomy / batch-review / epic-Phase-3 prompts.
   - New regex patterns / banlists in the epic-mode-guard hook.
   - Additional safety checks (timeout wrappers, heartbeat probes, output verification gates).
   - Additional rows in the supervisor failure taxonomy.

   **What MAY NEVER be patched (hard sandbox rejection)**:
   - `~/.claude/settings.json` or any settings file (user-owned).
   - `.git/`, `.ssh/`, `.env`, or any path outside the qshipmaster/qship skill dirs.
   - Business logic: `deliver_one_repo()`, `build_pr_body()`, `qshipmaster-plan.sh` wave-ordering algorithm, `merge-wave.sh` conflict resolution policy, `qshipcheck` verdict logic, the qship skill's pipeline-steps.md flow.
   - Anything that REMOVES an existing safety gate (timeout, hook, evidence requirement, marker word, etc.) — the script's allowlist of edit categories is additive-only.
   - Anything in your repos (the actual product code). If a recurring failure traces back to product-code bugs, that's a story for the engineering team, not a skill patch — the supervisor must ESCALATE.

   **Audit trail**: every self-applied patch logs to `~/.claude/skills/qshipmaster/self-improve.log` with timestamp, target file, confidence score, source URLs, rationale, backup path. The AGENTS.md gets a one-line entry that future workers see in their autonomy directive — so the LEARN-AND-PATCH cycle compounds across epics.

   **Safety belt — recursive failure detector**: if the supervisor observes the SAME failure class within the SAME epic AFTER a self-improve patch was applied (i.e. patch didn't work), it MUST escalate immediately and stop calling self-improve for that class. Two failed patch attempts at one class = clear signal that the issue needs human judgment.

   This step is OFF by default for the first run on any new pipeline. Set `QSHIPMASTER_SELF_IMPROVE=true` in the env to enable. Recommended once the skill has been used for ≥3 epics and the supervisor recipe is stable.

   ### Fully-autonomous mode — no user escalation

   Per the autonomy directive, the SELF-IMPROVE loop runs FULLY AUTONOMOUSLY with zero user blocking. No inbox-approval flow, no dry-run gate, no "escalate to user" exits. Whatever can't be patched cleanly THIS epic is **deferred to next epic with a different research strategy**.

   What this changes vs the original v1 design:

   | v1 (escalate-to-user) | v2 (fully autonomous) |
   |---|---|
   | Confidence < 75 → exit 1, ask user | Confidence < EFFECTIVE_FLOOR → record in `.deferred[]`, retry next epic with different search terms |
   | Sources < 3 → exit 1, ask user | Sources < 3 → defer + retry with widened query |
   | Source diversity < 3 unique domains → inbox alert | Diversity low → defer + retry with explicit "exclude already-cited domains" hint |
   | Sandbox violation → exit 2, alert user | Sandbox violation → defer + retry with different target file from allowlist |
   | First-N-uses dry-run for unfamiliar files | **Removed**. Auto-apply for all files. Safety provided by post-patch behavior verification (gap #1) + regression-streak auto-revert (gap #3). |
   | Recursion streak (2 failed patches) → escalate | Auto-revert + record in `.deferred[]` so next epic tries an alternative research strategy (e.g. "the previous fix was wrong; consider the opposite assumption"). |
   | VALIDATE_CMD missing → WARNING + syntax-only gate | Same (syntax-only) but no warning to user — logged in audit trail only |

   **In-run WebSearch-driven decision loop**: rather than defer immediately to the next epic when a quality gate rejects a proposal, the research stage now runs up to `QSHIPMASTER_MAX_RESEARCH_ATTEMPTS` (default 3) WebSearches in a row WITHIN THE CURRENT EPIC. Each attempt picks a DIFFERENT strategy based on what gate the previous attempt failed:

   | Previous gate failure | Next-attempt strategy |
   |---|---|
   | `low_diversity_*` | Exclude already-cited domains. Favour vendor docs / arxiv / IEEE / NIST / W3C over blogs. |
   | `insufficient_sources_*` | Broaden query — synonyms, related concepts, sibling terminology. |
   | `low_confidence_*` | Bias toward primary sources (RFCs, official docs, standards bodies). |
   | `research_inconclusive` | Widen scope OR attack a different layer of the stack (kernel → libc → runtime → framework → app). |
   | `sandbox_violation_*` | Pick a different file from the allowlist. |
   | `regression_streak_revert` (from prior epic) | Consider the OPPOSITE assumption about the root cause. |

   Each attempt's failure reason is appended to an in-run history file that the next attempt's prompt reads, so the LLM can explicitly pivot rather than re-running the same broken approach. Only after exhausting all 3 attempts does the wrapper defer to next epic.

   **Effective-floor adaptive softening**: if a failure key has been deferred ≥3 times across prior epics, the confidence floor drops by 25 points (default 75 → 50). Rationale: "bad-but-attempted patch with auto-revert safety net" beats "infinite paralysis". The downside is bounded by post-patch behavior verification, which still reverts patches that don't fix the failure.

   **Deferred-attempts ledger**: stored in `.patch-history.json` under `.deferred[]`. Each entry: `{key, epic, deferred_at, reason, proposal_path}`. The research-stage prompt now reads this ledger and explicitly instructs the LLM to "use DIFFERENT search domains than prior attempts", "consider the OPPOSITE assumption about the root cause", or "attack a different layer of the stack" depending on the reason of the prior deferral.

   **Risk acknowledged**: the 2026 RSI literature (Alcaraz, ICLR 2026 workshop) warns that removing human gates increases drift risk. The user has explicitly accepted this risk. The remaining safety net is:
   - Post-patch behavior verification (auto-revert if fix didn't work)
   - Regression-streak auto-revert (auto-revert if recurrence persists)
   - Path-sandbox (allowlist of patchable files — never touch settings, .git, .ssh, .env, business logic)
   - Syntax check (auto-revert on bash -n failure)
   - All patches go through git commits — full history audit, manual `git revert` is always possible after the fact.

   ### Hardenings against the 2026 RSI literature's "verifiability gap"

   The qwebsearchanalysis 2026 review of recursive-self-improvement research identified five gaps in the v1 self-improve design (Alcaraz's verifiability constraint, SICA's multi-objective scoring, the rollback-pattern playbook). All five are now implemented in `qshipmaster-self-improve.sh` + `qshipmaster-track-outcome.sh`:

   **Gap #1 — Post-patch behavior verification (CRITICAL).**
   The diagnosis markdown the supervisor writes MUST include a `## VALIDATE_CMD` section containing a shell command that exits 0 when the failure is fixed, non-zero otherwise. Example:
   ```markdown
   ## VALIDATE_CMD
   ```
   bash -c 'cd {{STATE_ROOT}}/worktrees/{{JIRA_PROJECT_KEY}}-EX10/{{PRIMARY_REPO_NAME}} && pytest tests/api/v1/test_records.py::test_list_endpoint -x'
   ```
   ```
   The self-improve wrapper extracts this, runs it AFTER the patch lands (300s wall-clock cap), and if it still exits non-zero, the patch is auto-reverted from backup AND marked in history as a failed attempt so future runs won't retry the same patch. Without this section, the wrapper falls back to syntax-only verification and logs a WARNING in the audit log — that's the pre-2026 weak gate, kept only for graceful degradation.

   **Gap #2 — Git-as-rollback-engine.**
   The wrapper now `git init`s a hidden repo at `~/.claude/skills/qshipmaster/.git` on first run (separate from the user's own git config — author email `self-improve@qshipmaster.local`). Every patch is committed there with message `[SELF-IMPROVE: <key>] confidence=N verified=PASS|FAIL|UNKNOWN epic=<id>`. Rollback = `git revert <sha>` (richer than `cp` because of blame trail + diff history). Filesystem `cp` backups are kept as belt-and-suspenders for files outside the SKILL_ROOT git repo (e.g. `qship-persist.sh` lives under `~/.claude/skills/qship/` — outside the new repo).

   **Gap #3 — Per-version outcome telemetry + regression-streak auto-revert.**
   New file `~/.claude/skills/qshipmaster/.patch-history.json` records every patch with `outcomes.epics_observed[]`. After each epic finishes, supervisor MUST call `bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-track-outcome.sh <EPIC>`. That script:
   - Greps the epic's qshipmaster.log for `FAILURE_CLASS=<key>` markers (supervisor MUST emit these whenever it observes a failure).
   - For each active patch, records PASS (class didn't fire) or FAIL (class fired again — patch ineffective).
   - If a patch's last `QSHIPMASTER_REGRESSION_STREAK` (default 3) observations are all FAIL, the patch is **auto-reverted** via `git revert` + filesystem restore + inbox alert. Marks `patches[i].reverted=true` so future runs won't reapply.

   **Gap #4 — First-N-uses dry-run.**
   For any target file with fewer than `QSHIPMASTER_FIRST_N_USES_DRY_RUN` (default 3) prior patches, the wrapper runs in DRY-RUN mode: writes the full proposal to `{{STATE_ROOT}}/epic-<EPIC>/inbox/self-improve-dryrun-<key>-<ts>.md` and exits 4 WITHOUT applying. User must manually review + opt-in. This builds operator trust on a per-file gradient — frequently-patched files get auto-apply, fresh files stay propose-only.

   **Gap #5 — Source diversity audit.**
   The research step now requires ≥3 **unique domains** (not just ≥3 URLs — 3 Stack Overflow links don't count as 3 sources). The wrapper also runs a trend check: if the last 10 patches across the whole history collectively cite fewer than 5 unique domains, it logs a WARNING about echo-chamber drift. The user can inspect `.patch-history.json` to see the source diversity trajectory.

   ### Required supervisor obligation: emit FAILURE_CLASS markers

   For gap #3's outcome tracking to work, the supervisor's poll loop MUST emit a line of the form `FAILURE_CLASS=<snake_case_key>` to the qshipmaster.log every time it observes a known failure class — even when it's healed reactively. The track-outcome.sh script greps for these. Without the markers, gap #3 cannot distinguish "class didn't recur" from "class did recur but wasn't logged."

Sources for this self-improve design: [Self-Healing Agent Pattern (dev.to)](https://dev.to/the_bookmaster/the-self-healing-agent-pattern-how-to-build-ai-systems-that-recover-from-failure-automatically-3945), [FutureSpeakAI controlled self-modification](https://github.com/FutureSpeakAI/agent-fridays-self-improvement-kit), [Self-Improving AI Agents 2026 Guide (o-mega)](https://o-mega.ai/articles/self-improving-ai-agents-the-2026-guide), [ICLR 2026 Recursive Self-Improvement Workshop](https://recursive-workshop.github.io/), [QA Wolf: 6 Types of AI Self-Healing](https://www.qawolf.com/blog/self-healing-test-automation-types), [AI Self-Improvement Only Works Where Outcomes Are Verifiable (Alcaraz)](https://gist.github.com/AnthonyAlcaraz/a0b70a4bb5ce521129e93bf9d33f9698), [Rollback — Encyclopedia of Agentic Coding Patterns](https://aipatternbook.com/rollback), [SWE-bench in 2026 evaluation standards (CallSphere)](https://callsphere.ai/blog/swe-bench-evaluating-agentic-coding-agents).
```

### What "ESCALATE" means concretely
- Report the symptom + relevant log excerpt to the user in a single message.
- Do NOT schedule another wakeup (the loop pauses).
- Wait for the user's response. When they reply with go-ahead or a manual fix, resume the loop.

### What "STOP looping" means
- `status == "shipped"`: report final PR URLs and a per-wave summary; do not schedule further wakeups.
- Manual user kill of the orchestrator: skip the wakeup; do not auto-relaunch a manually-killed run.

### Why 270s (not 300s)
The Anthropic prompt cache has a 5-minute TTL. Sleeping 300s straddles the boundary and pays a cache miss every cycle. 270s stays warm — same observability cadence, ~20× cheaper context cost over a 10h epic.

Sources for this recipe: [Building Self-Healing AI Agents with Claude API (Claude Lab)](https://claudelab.net/en/articles/api-sdk/claude-api-self-healing-agent-production-patterns), [Latitude AI agent failure detection guide](https://latitude.so/blog/ai-agent-failure-detection-guide), [Exception Handling in Agentic AI (atalupadhyay)](https://atalupadhyay.wordpress.com/2026/03/16/exception-handling-and-recovery-in-agentic-ai/), [The Self-Healing Agent Pattern (dev.to)](https://dev.to/the_bookmaster/the-self-healing-agent-pattern-how-to-build-ai-systems-that-recover-from-failure-automatically-3945).

## State model

All state lives in `{{STATE_ROOT}}/epic-<EPIC>/state.json`:

```json
{
  "epic": "{{JIRA_PROJECT_KEY}}-EX01",
  "epic_summary": "{{PRIMARY_REPO_NAME}}-restructure",
  "epic_branch": "{{JIRA_PROJECT_KEY}}-EX01-{{PRIMARY_REPO_NAME}}-restructure",
  "repos": ["{{PRIMARY_REPO_NAME}}"],
  "base_branch": "develop",
  "waves": [
    {
      "n": 1,
      "tickets": ["{{JIRA_PROJECT_KEY}}-EX01b", "{{JIRA_PROJECT_KEY}}-554", "{{JIRA_PROJECT_KEY}}-555", "{{JIRA_PROJECT_KEY}}-556"],
      "status": "shipped",
      "merged_at": "2026-04-29T10:14:00Z",
      "phase2_passed": true,
      "wave_phase3_evidence": "{{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX01/wave-1-phase3-evidence.md"
    },
    {
      "n": 2,
      "tickets": ["{{JIRA_PROJECT_KEY}}-557", "{{JIRA_PROJECT_KEY}}-558", "{{JIRA_PROJECT_KEY}}-559"],
      "status": "in_flight",
      "tickets_passed": ["{{JIRA_PROJECT_KEY}}-557"],
      "tickets_pending": ["{{JIRA_PROJECT_KEY}}-558", "{{JIRA_PROJECT_KEY}}-559"]
    },
    { "n": 3, "tickets": ["{{JIRA_PROJECT_KEY}}-560"], "status": "pending" },
    { "n": 4, "tickets": ["{{JIRA_PROJECT_KEY}}-561", "{{JIRA_PROJECT_KEY}}-562"], "status": "pending" }
  ],
  "pr_url_per_repo": {},
  "status": "in_flight"
}
```

Each step writes only its own keys. **Never overwrite** the file — use `jq` + `mv` atomic update via `qshipmaster-state.sh` helpers.

## Wave plan construction

`qshipmaster-plan.sh <EPIC>` builds the plan. **Model:** defaults to `opus[1m]` at `xhigh` effort (override via `QSHIP_PLAN_MODEL` / `QSHIP_PLAN_EFFORT`). Rationale: this single call decides the entire epic's execution shape — a wrong wave plan cascades through 10-15 h of downstream work — so the planner gets the strongest available model + reasoning depth and the 1M context window for long child descriptions / Blocked-by rationales.

1. Fetch epic via `getJiraIssue`. Capture `summary`, `issuetype`, status. Verify `issuetype == "Epic"` — fail loudly otherwise.
2. Fetch children with `searchJiraIssuesUsingJql jql="parent = <EPIC>" fields=["summary","status","description"]`.
3. For each child, parse `Blocked by:` lines from the description. Build a DAG of `child → blockers`.
4. Topological sort: Wave 1 = nodes with no blockers; Wave N = nodes whose blockers are all in Waves 1..N-1.
5. Detect repos by inspecting each child's description for the canonical repo header (`## Repo: <name>`) — fall back to grepping the description for any repo name listed in `repos.json`.
6. Slugify epic summary to produce `epic_branch`. Strip non-alnum, lowercase, hyphenate, prefix with epic id: `{{JIRA_PROJECT_KEY}}-EX01-{{PRIMARY_REPO_NAME}}-restructure`.
7. Write the plan to `state.json`.

If the DAG has a cycle, HALT and emit the cycle in `state.json.error` for the user to fix in Jira.

## Wave execution loop (per wave)

For each wave with `status != "shipped"`:

### Step 1 — Worktree base branch resolution

- **Wave 1**: BASE_BRANCH = `develop` (or whatever `state.json.base_branch` says).
- **Wave N>1**: BASE_BRANCH = `state.json.epic_branch` at its current tip (post Wave N-1 merge). This is post-patch §6 — workers in Wave 2+ MUST see Waves 1..N-1's structural changes.

For each ticket in the wave, ensure its worktree exists at `{{STATE_ROOT}}/worktrees/<TICKET>/{{COMPANY_SLUG}}-<repo>` based on BASE_BRANCH:

```bash
git worktree add -b <ticket-branch> {{STATE_ROOT}}/worktrees/<TICKET>/{{COMPANY_SLUG}}-<repo> <BASE_BRANCH>

# Initialize codegraph in the new worktree (background, non-blocking).
# Skipped silently if the worktree already had .codegraph/ from a prior run.
if [ ! -d {{STATE_ROOT}}/worktrees/<TICKET>/{{COMPANY_SLUG}}-<repo>/.codegraph ]; then
  codegraph init {{STATE_ROOT}}/worktrees/<TICKET>/{{COMPANY_SLUG}}-<repo> 2>/dev/null \
    && cp {{CODEBASE_ROOT}}/.codegraph/config.json \
          {{STATE_ROOT}}/worktrees/<TICKET>/{{COMPANY_SLUG}}-<repo>/.codegraph/config.json 2>/dev/null \
    && nohup codegraph index {{STATE_ROOT}}/worktrees/<TICKET>/{{COMPANY_SLUG}}-<repo> \
         > /tmp/codegraph-init-<TICKET>-{{COMPANY_SLUG}}-<repo>.log 2>&1 &
fi
```

This is purely additive: `qship-worker` uses `mcp__codegraph__*` tools that resolve from the worktree's `.codegraph/`. If init/indexing isn't done by the time the worker queries, the tools degrade to "not initialized" — the worker still functions via grep/Read fallback, just without semantic search for that wave.

If a worktree already exists from a prior run, leave it; the inner `qship-persist.sh` is itself resumable.

### Step 2 — Parallel ticket execution with EPIC_MODE

For each ticket in the wave, spawn:

```bash
EPIC_MODE=true \
EPIC_ID=<EPIC> \
EPIC_STATE_FILE={{STATE_ROOT}}/epic-<EPIC>/state.json \
nohup bash ~/.claude/skills/qship/hooks/qship-persist.sh <TICKET> \
  > {{STATE_ROOT}}/epic-<EPIC>/logs/<TICKET>-persist.log 2>&1 &
```

The `EPIC_MODE` env var is the contract from post-patch §1: `qship`'s Phase 4 worker sees the var, registers `EPIC_ID` and `state.json` location, and:
- DOES write the implementation, run lint/black/isort, run unit tests against the worktree.
- DOES write `phase3-evidence.md` per ticket (still needed for `qshipcheck` PASSED).
- DOES NOT push the branch to origin.
- DOES NOT call `gh pr create`.

Track PIDs in `state.json.waves[N].pids` so re-runs can detect already-running children.

### Step 3 — Wave barrier (block until all PASSED)

Loop with 60s polling. **Completion signal = atomic flag file**, not log grep:

```
for ticket in wave.tickets:
    if {{STATE_ROOT}}/worktrees/<ticket>/qshipcheck-PASSED.flag exists → mark passed
    elif persist log shows "GAVE UP after MAX_ITERS" → mark blocked, escalate
    else → still in flight
```

The flag is written by `qship-persist.sh::ticket_is_complete` (atomic via `mv` from a `.tmp` file) when both conditions hold: positive verdict pattern matched AND no failure markers present in the qshipcheck log. Log-grep was the original approach and was fragile to log-format changes; the flag is the discrete signal, the log remains as evidence.

**Stuck-progress detector** — Huntley's "fix_plan repetitive" guard ([ghuntley.com/ralph](https://ghuntley.com/ralph/)). Snapshot `tickets_pending` after every poll; if its sha1 is unchanged for `STALL_POLLS=15` consecutive polls (default ~15min at 60s/poll), HALT with `state.json.error = "wave N stalled"` instead of waiting out `MAX_WAVE_ITERS`. Wall-clock timeout still applies as the outer bound.

Update `tickets_passed` / `tickets_pending` in state.json after each poll.

When `tickets_pending` is empty AND no ticket is `blocked`, proceed to Step 4. If any ticket is `blocked` or stalled, HALT, write the blocking reason to `state.json.error`, and yield.

### Step 4 — Wave merge into consolidated epic branch

`qshipmaster-merge-wave.sh <EPIC> <wave_n>`:

```bash
cd <repo>
git fetch --all
git checkout <epic_branch> 2>/dev/null || git checkout -b <epic_branch> <base_branch>

for ticket_branch in $(jq -r '.waves[wave_n-1].tickets[]' state.json | xargs -I{} echo "{}-..."); do
    git merge --no-ff $ticket_branch -m "merge: $ticket_branch into $epic_branch"
done
```

**Conflict resolution policy** (per qship SKILL.md §12.2 — additive merge):
- `index.js` exports → keep ALL exports from both sides
- `component_wrapper.py` → keep ALL wrapper functions
- `app.py` page registrations / nav entries / badge configs → keep ALL
- `__init__.py` package exports → keep ALL
- For non-additive conflicts (same line, different content) → drop into SendMessage flow:
  - Send a message to the human caller with the conflict file paths and `git diff --name-only --diff-filter=U` output
  - Wait for user response with resolution instruction
  - Apply the resolution and continue

### Step 5 — Wave review (lightweight gate by default; full Phase 2 deferred to epic-end)

**Default behaviour:** a lightweight **wave-gate** runs after each wave merge. The full Phase 2 (all rows in the step inventory below) runs ONCE at epic-end on the cumulative merged diff. See [`wave-gate.md`](wave-gate.md) for the full procedure and rationale.

The wave-gate is the middle ground between two prior defaults:
- Old behaviour (full Phase 2 per wave): expensive. 9+ Opus review agents per wave, most findings re-litigated at epic-end.
- Intermediate behaviour (skip per-wave entirely): cheap but unsafe. A Wave 1 logic bug can survive into Wave 2+ before anyone notices.

**The gate runs four cheap checks per wave** (full procedure in `wave-gate.md`):
1. Migration chain check (mechanical, alembic-touching waves only)
2. Typecheck + targeted tests on touched files only
3. **qbug-lite**: 2 hunters (`logic-error-detector` + `silent-failure-hunter`) seeing ONLY the diff + touched files — no implementer rationale (validator independence per [MindStudio 2026](https://www.mindstudio.ai/blog/automated-code-review-multiple-ai-agents))
4. qbcheck filters the hunter claims; **block on Critical only**, defer Highs/Mediums to epic-end via `wave-<N>-deferred-findings.md`

**Toggle precedence** (read `wave-gate.md` §"Toggle precedence" for the full table):

| `QSHIP_PER_WAVE_REVIEW` | Behavior |
|---|---|
| `gate` (or unset — default) | Lightweight wave-gate. **Recommended.** |
| `full` | Restore full Phase 2 per wave (the inventory below). |
| `none` | Skip everything per wave. Epic-end Phase 2 is the only safety net. |

Legacy `QSHIP_PER_WAVE_PHASE2=true` is honored as an alias for `=full`; `QSHIP_PER_WAVE_PHASE2=false` as an alias for `=none`. If both vars are set, `QSHIP_PER_WAVE_REVIEW` wins. Always record the resolved mode in `state.json.waves[N].review_mode`.

**Phase 2 step inventory (full spec lives in `qship/pipeline-steps.md` §7.5–§11.7).** This inventory runs:
- **By default**: ONCE at epic-end on the cumulative merged diff (`git diff <state.json.base_branch>..HEAD`), consuming all `wave-<N>-deferred-findings.md` files as additional input.
- **Under `QSHIP_PER_WAVE_REVIEW=full`**: once per wave on the wave's merged diff, AND again at epic-end on the cumulative diff (for stable defaults parity).

In order:

| Sub-step | Skill / agent | When required |
|----------|---------------|---------------|
| 7.5 Simplify | `code-simplifier:code-simplifier` (must APPLY edits, see §7.5.3) | Always |
| 8.3 Reviews | Agents 1, 2 (orchestrator) + `qcheckt` (Skill) + Agent 4 spec | Always |
| 8.5.1 Migration chain | `/qmigrationdevcheck` | If diff touches `*/alembic/versions/` |
| 8.6.5 Trailing-slash | `/qauthtrailingslash` | If diff touches FastAPI routes or React `fetchJson` |
| 8.8 Synthesis | Write `phase2-findings.md` | Always |
| 9–10 Bug hunt + qbcheck | bug-hunter swarm + validation | Always |
| 11 Fix issues | Tick every MUST FIX in `phase2-findings.md` (no silent skips) | Always |
| 11.5 Verification gate | Tests + format + findings closure audit | Always (hard gate) |
| 11.6 Quick E2E | `/qe2etest` | Always |
| 11.7 Memory capture | `/qmemory` | If trigger matrix in §11.7 fires |

The fix-only worker dispatched by `qshipmaster` MUST execute every applicable row above (it inherits the qship spec). If a row is skipped, `qshipphasecheck phase2` blocks PR creation.

**Epic-end Phase 2 also consumes wave-gate deferred findings:** when reading inputs for Step 8 / Step 9 at epic-end, also load every `{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-deferred-findings.md` written by the gates. The reviewer/hunter agents see these as "prior wave-gate findings — re-evaluate against the final code state." Some will be incidentally fixed by later waves and drop out; some remain live and get promoted into the epic-end finding set. No signal lost.

When `QSHIP_PER_WAVE_REVIEW=full` (legacy `QSHIP_PER_WAVE_PHASE2=true`), the inventory above runs ONCE per wave on the merged diff `git diff <prev_epic_tip>..HEAD` (NOT once per ticket — post-patch §2), in addition to the epic-end pass:

```bash
# Use pyenv-resolved python (post-patch §8)
export PATH="{{USER_HOME}}/.pyenv/shims:$PATH"

# Lint + format
black --check .
isort --check-only .
flake8

# Tests
pytest tests/ -v --tb=short
```

If any check fails:
1. Dispatch a fix-only worker with the failing output and the wave's merged diff.
2. **The worker prompt MUST forbid placeholder fixes** (Huntley's "DO NOT IMPLEMENT PLACEHOLDER" rule, [ghuntley.com/ralph](https://ghuntley.com/ralph/)). Specifically banned as "fixes":
   - `pytest.skip` / `pytest.xfail` / `@pytest.mark.skip` on the failing test
   - replacing assertions with `assert True` or weakened checks
   - deleting the failing test
   - `try/except: pass` to swallow the error
   - editing `# noqa` / `# type: ignore` to mute the lint
   - stubbing the function-under-test to return a hardcoded value
   If the failure is genuinely out-of-scope or a real bug the wave's tickets don't own, the worker writes a diagnosis to `wave-N-blocked.md` and exits non-zero — qshipmaster halts and surfaces to the user. Faking green is worse than halting.
3. Worker commits fixes onto `<epic_branch>` directly (not onto a ticket branch).
4. Re-run the checks. Loop with `MAX_FIX_ITERS=3` cap. After 3, HALT and yield.

When all lint/test green, run `/qe2etest` against the running local stack on the wave's merged branch tip (see "Per-wave Phase 3 evidence contract" in `wave-gate.md`). Capture output to `{{STATE_ROOT}}/epic-<EPIC>/wave-<N>-qe2etest.log` and per-scenario artifacts under `wave-<N>-qe2etest-artifacts/`. If `/qe2etest` FAILs, dispatch the same fix-only worker contract (no `pytest.skip`-equivalents, no test deletion) and re-run. `MAX_FIX_ITERS=3`. After 3 failures, HALT — do not flip the wave.

Then write `wave-<N>-phase3-evidence.md` summarizing:
- Wave number, ticket list
- Lint/test command outputs (last lines) — labeled as Phase 2 verification, NOT Phase 3 evidence
- Files touched per ticket
- Net merged diff stats
- `## Phase 3 — /qe2etest evidence` section with the invocation line, the PASS verdict from `wave-<N>-qe2etest.log`, and a bullet list of scenarios exercised with artifact paths. Skip clause `no qe2etest surface: <reason>` only valid when the merged diff touches zero FastAPI routes / React components / `fetchJson(` calls / endpoint-reachable alembic columns.

Mark `state.json.waves[N].status = "shipped"`. Proceed to Wave N+1.

## Final delivery (after last wave)

`qshipmaster-deliver.sh <EPIC>`:

0. **Epic-end `/qe2etest` gate (HARD PRECONDITION — invariant I8).** Run `/qe2etest` ONE more time against the cumulative epic branch (`git diff <state.json.base_branch>..HEAD`). Write output to `{{STATE_ROOT}}/epic-<EPIC>/epic-qe2etest.log`. Block delivery until the log shows PASS or carries a `no qe2etest surface: <reason>` rationale consistent with the cumulative diff. This catches cross-wave integration drift that per-wave `/qe2etest` cannot see (wave-1 schema rename × wave-4 caller update — neither wave-isolated run fails, the integrated branch does). If FAIL, dispatch fix-only worker (same banlist as Phase 2 fix loop) and re-run. `MAX_FIX_ITERS=3`. After 3, HALT and surface to the user — do NOT create PRs over a failing epic-end E2E.
1. **Per repo**: push `<epic_branch>` to origin with `--set-upstream`.
2. **Per repo**: create ONE consolidated PR using qship SKILL.md §12.3 template:
   - Title: `${EPIC_ID} ${EPIC_TITLE}`
   - Body: Summary + Stories Included table (one row per child) + Jira link + Test plan checklist
   - Base: `develop` (or `state.json.base_branch`)
3. **Primary review** — run `code-review:code-review` skill on each PR. Defaults to `opus[1m]` at `high` reasoning effort (matches the pipeline-wide review pattern). Override via `QSHIP_PR_REVIEW_MODEL` / `QSHIP_PR_REVIEW_EFFORT`.
4. **External-family critic** — invoke a critic in a different LLM family from the primary reviewer (which ran on `opus[1m]`). Engine selection (`qshipmaster-deliver.sh:165`) mirrors the user's Phase 2 reviewer opt-in:
   - **When `reviewer=codex` was passed to `/qship` or `/qshipmaster`** (exports `QSHIP_REVIEW_ENGINE=codex`) AND `codex` CLI is available: critic runs as `codex exec --model gpt-5.5 -c model_reasoning_effort=high`. The orchestrator gathers `gh pr diff` + existing review comments on the Claude side, ships them via stdin (no codex-side `gh` permissions needed), writes the assistant's final message via codex's `-o` flag, and posts it back via `gh pr comment`. This is the diversified opus-implements + codex-reviews stance applied end-to-end.
   - **Otherwise (default — `reviewer=claude` or no flag):** critic runs as `claude --model sonnet` with read-only tools (`Bash,Read,Grep,Glob`). Sonnet posts its own comment directly with the existing prompt. Cross-family second opinion (opus → sonnet) is still preserved even without codex involvement.
   - **Force override:** `QSHIP_CRITIC_ENGINE=codex` or `QSHIP_CRITIC_ENGINE=sonnet` short-circuits the resolution and pins one engine regardless of `QSHIP_REVIEW_ENGINE`. Codex-side failures (non-zero exit, missing output file) automatically fall back to the sonnet path with a log line.

   Both engines hunt the same blind spots — cross-file invariants the diff breaks, silent failures, test-coverage gaps for the new behaviour, security implications, data-shape contracts — and post ONE consolidated `## <Engine> critic — second opinion` comment (or `— no additional findings` and stop). Pattern from [ralphex](https://ralphex.com/) Phase 3: different model family catches what the primary missed. Cheap, fast, ~30 seconds per PR.

   Override knobs: `QSHIP_CRITIC_ENGINE={codex|sonnet}`, `QSHIP_CODEX_CRITIC_MODEL` (default `gpt-5.5`), `QSHIP_CODEX_CRITIC_EFFORT` (default `high`).
5. Post a final summary comment on each PR with the per-wave pytest tallies from `wave-<N>-phase3-evidence.md`.
6. Update `state.json.pr_url_per_repo` and set `state.json.status = "shipped"`.
7. Yield with: `"qshipmaster complete. <N> waves, <M> tickets shipped via <K> consolidated PR(s): <list>"`.

## Cross-epic procedural memory (`AGENTS.md`)

After every Phase 2 fix iteration, `qshipmaster-learn.sh` is invoked to capture what broke and how it was fixed. Pattern from [ralph-zero](https://github.com/davidkimai/ralph-zero) (mandatory `AGENTS.md` documentation injected into each fresh session).

Flow per fix iteration:
1. `qshipmaster-learn.sh <EPIC> <wave_n> <repo> <fix_iter>` reads `wave-N-<repo>-phase2.log` (the failures) + the corresponding fix-worker log (what got changed).
2. A haiku call extracts exactly 3 lines: `ROOT_CAUSE`, `FIX`, `RULE`.
3. The entry is appended to `~/.claude/skills/qshipmaster/AGENTS.md` with a unique key marker (`<EPIC>-wave<N>-<repo>-iter<I>`) for idempotence — re-running never duplicates entries.

Re-injection happens at the worker layer, not the orchestrator: `qship-persist.sh::build_claude_flags` reads the most recent ~15 entries from `AGENTS.md` and folds them into the autonomy directive that ships to every per-ticket `claude -p` call. Workers see prior cross-epic pitfalls before they start writing code. The 15-entry cap keeps context overhead bounded; older entries remain in `AGENTS.md` as historical record but stop being injected.

The fix-worker prompt also explicitly tells the worker to read `AGENTS.md` first when fixing a Phase 2 failure, so wave-level fixes are informed by what bit prior waves.

## Idempotence + recovery

The skill MUST be re-runnable at every point. Specifically:

| Re-run trigger | Expected behaviour |
|---|---|
| Re-run on a fully shipped epic | `qshipmaster-plan.sh` rebuilds plan, sees `state.json.status = "shipped"`, exits with "epic already shipped, PR(s): <urls>". |
| Re-run after `state.json` deleted on a shipped epic | Re-builds plan from Jira; checks each ticket's branch on origin; sees the consolidated PR exists; rebuilds state.json from observation; exits with "shipped" verdict. |
| Re-run mid-wave-2 after crash | Rebuilds plan; sees Wave 1 `shipped`, Wave 2 `in_flight`; for each Wave 2 ticket, re-checks `qshipcheck` flag; resumes barrier polling. |
| Re-run after a wave merge crashed mid-conflict | Detects unmerged paths via `git diff --name-only --diff-filter=U`; re-enters SendMessage flow on the same files. |

The `qshipmaster-run.sh` script's first action is always: `qshipmaster-plan.sh && qshipmaster-state-status` — produces the diagnosis before any action.

## Test case — {{JIRA_PROJECT_KEY}}-EX01

Use {{JIRA_PROJECT_KEY}}-EX01 as the canonical regression case:

```bash
# Re-run on already-shipped epic
bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-run.sh {{JIRA_PROJECT_KEY}}-EX01
# Expected: "epic already shipped, PR <url> merged"

# Reset and re-run
rm -rf {{STATE_ROOT}}/epic-{{JIRA_PROJECT_KEY}}-EX01
bash ~/.claude/skills/qshipmaster/hooks/qshipmaster-run.sh {{JIRA_PROJECT_KEY}}-EX01
# Expected: rebuilds plan, sees all 12 tickets DONE in Jira and all branches in origin,
# detects existing consolidated PR, exits "shipped" without re-merging.
```

## File map

```
~/.claude/skills/qshipmaster/
├── SKILL.md                          (this file)
├── wave-gate.md                      lightweight per-wave review procedure (default)
├── AGENTS.md                         cross-epic procedural memory (auto-grown)
└── hooks/
    ├── qshipmaster-run.sh            outer entry point — composes the others
    ├── qshipmaster-plan.sh           Jira fetch → state.json wave plan
    ├── qshipmaster-state.sh          atomic state.json read/write helpers
    ├── qshipmaster-merge-wave.sh     wave merge + conflict policy
    ├── qshipmaster-deliver.sh        final push, PR, primary review, external-family critic (codex default / sonnet fallback)
    └── qshipmaster-learn.sh          extract root-cause + rule from a fix iter, append to AGENTS.md
```

## Reference implementations studied

The orchestration pattern composes ideas from three Ralph-Loop derivatives:
- `ralph-zero` (skill-package over ralph loop) → SKILL.md format, hook layout.
- `multi-agent-ralph-loop` (parallel agent teams + quality gates) → wave fan-out + barrier pattern.
- `ralphex.com` (orchestrator that runs implementation plans then multi-agent review) → wave-level Phase 2 review + per-PR `code-review` integration.

The qship primitives (`qship-persist.sh`, hooks) supply per-ticket persistence and gate enforcement; `qshipmaster` is purely the epic-level layer above them.
