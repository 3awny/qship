# Reviewer Override — Analysis via `codex exec` (gpt-5.5 high)

This file replaces the **analysis dispatches** inside qship's review-flavoured steps:

- **Step 6** — Plan Review (`qplan`) in Phase 1
- **Step 7.5** — Simplify (`code-simplifier`) in Phase 2
- **Step 8** — Code Review fan-out in Phase 2 (excluding §8.5.1 qmigrationdevcheck and §8.6.5 qauthtrailingslash — see swap table)
- **Step 9** — Bug Hunt (`qbug`) in Phase 2
- **Step 10** — Bug Validation (`qbcheck`) in Phase 2

It does NOT replace Step 5 (Write Plan — generative, not review), Step 7 (Implement), Step 11 (Fix), Step 11.5 (Verification Gate), Step 11.6 (`/qe2etest`), or Step 11.7 (`/qmemory`) — those always run as Claude.

Activate this override only when the orchestrator was invoked with `reviewer=codex` (equivalently, when `$QSHIP_REVIEW_ENGINE=codex` is set in the worker environment).

## TL;DR of the swap

| Step | Default (REVIEWER=claude) | This override (REVIEWER=codex) |
|---|---|---|
| 6 Plan Review (qplan) | Worker follows the pre-loaded `qplan` skill | `codex exec --model gpt-5.5 -c model_reasoning_effort=high` told to follow `~/.codex/skills/qplan/SKILL.md` against the plan file |
| 7.5 Simplify | `Task(subagent_type: "code-simplifier:code-simplifier", ...)` | `codex exec --model gpt-5.5 -c model_reasoning_effort=high` with the simplifier prompt |
| 8.1 Superpowers Code Reviewer | `Task(subagent_type: "superpowers:code-reviewer", ...)` | `codex exec` with the same prompt body |
| 8.2 Feature-Dev Code Reviewer | `Task(subagent_type: "feature-dev:code-reviewer", ...)` | `codex exec` with the same prompt body |
| 8.3 Tests Reviewer (qcheckt) | `Skill: qcheckt` | `codex exec` told to follow `~/.codex/skills/qcheckt/SKILL.md` |
| 8.4 Spec Compliance Reviewer | `Task(subagent_type: "general-purpose", ...)` | `codex exec` with the spec-compliance prompt |
| 8.5.1 qmigrationdevcheck (alembic) | `Skill: qmigrationdevcheck` | **Stays in Claude.** Alembic chain analysis depends on Claude's tenant-stamp memory + the qmigrationdevcheck skill's deeper tool integration. Not a codex fit. |
| 8.6.5 qauthtrailingslash | `Skill: qauthtrailingslash` | **Stays in Claude.** Same reason as 8.5.1 — narrow, tool-driven, low-value to route through codex. |
| 9 Bug Hunt (1–5 hunter agents) | parallel `Task(subagent_type: "bug-hunter", ...)` | parallel `codex exec` calls with the bug-hunt prompt |
| 10 qbcheck (Bug Validation) | `Skill: qbcheck` | `codex exec` told to follow `~/.codex/skills/qbcheck/SKILL.md` |

Claude stays the orchestrator. Codex is a per-step subprocess. Output format (the `phase2-findings.md` file consumed by Step 11) is unchanged — Claude parses Codex's response and writes the file itself.

## Skill access for Codex

Codex CLI auto-discovers skills from `~/.codex/skills/<name>/SKILL.md`. These are symlinks into `~/.agent-skills/`, which is the same target `~/.claude/skills` points at, so:

- Every Claude skill (qcheckt, qclean, qbug, qbcheck, qreuse, qcheckf, qmigrationdevcheck, qauthtrailingslash, etc.) is reachable from `codex exec` via `/skills <name>` or by mentioning `$<skill-name>` in the prompt — see [Codex Agent Skills docs](https://developers.openai.com/codex/skills).
- After adding or deleting a skill, run `sync-agent-skills` to refresh the Codex side of the symlink farm.
- SKILL.md frontmatter (`name`, `description`) is interoperable between the two CLIs — skill bodies that reference Claude-only tools (Task, Skill, TodoWrite) won't execute under Codex, but the *guidance* in the body still informs Codex's review.

## The per-step `codex exec` invocation pattern

For each Phase 2 review slot the orchestrator would otherwise dispatch a Task subagent, build a prompt as before, then shell out to:

```bash
codex exec \
  --model "${QSHIP_CODEX_REVIEWER_MODEL:-gpt-5.5}" \
  -c model_reasoning_effort="${QSHIP_CODEX_REVIEWER_EFFORT:-high}" \
  --json \
  --working-dir "$WORKTREE" \
  - < "$PROMPT_FILE" \
  | tee "$WORKTREE/codex-reviews/step-${STEP}-${AGENT_SLOT}.jsonl"
```

Key flags:

- `--json` emits JSONL events Claude can parse for the final assistant message.
- `--working-dir` pins codex to the ticket worktree so its working tree, git index, and per-repo CLAUDE.md / AGENTS.md are visible.
- Stdin is the prompt body (heredoc or file). Same prompt content as the Claude Task subagent would have received.

The orchestrator captures three artifacts per slot:

```
<WORKTREE>/codex-reviews/step-<STEP>-<AGENT_SLOT>.jsonl   # raw event stream
<WORKTREE>/codex-reviews/step-<STEP>-<AGENT_SLOT>.md      # extracted final message
<WORKTREE>/codex-reviews/step-<STEP>-<AGENT_SLOT>.summary # one-paragraph human summary
```

These feed into the standard `phase2-findings.md` aggregation in Step 8.8 — the format expected by `require-pipeline-complete.sh` is unchanged.

## Per-step prompt templates

### Step 6 — Plan Review (replaces the Claude `qplan` invocation)

In Phase 1, after Step 5 (Write Plan) produces `<WORKTREE>/plan.md` (or per-repo plan files), Claude builds the prompt below and dispatches `codex exec` instead of running the `qplan` skill itself. Codex returns a verdict + punch list; Claude reads it and either (a) revises the plan in place per the punch list and re-runs Step 6, or (b) records a `passed` result in `phase2-progress.md`'s plan-review row and proceeds to Step 7.

Prompt body:

```
You are reviewing an implementation plan before any code is written.
Follow ~/.codex/skills/qplan/SKILL.md exactly — it is the canonical
review rubric. Do NOT rewrite the plan; output a verdict + punch list
of changes the plan author should make.

## Plan (the artifact under review)
<paste full contents of <WORKTREE>/plan.md, or per-repo plan files concatenated>

## Source of truth for requirements
Ticket: <TICKET_ID>
Summary: <TICKET_SUMMARY>
Acceptance criteria:
<paste ACs from Step 1>

## Scope hints
Repos affected: <list from Step 2 — read from repos.json>
Branches in flight (cross-ticket dependencies): <from D2 resolution>

## Output

Use the SKILL.md rubric headings. At minimum produce:

  ### Verdict
  <PASS | REVISE | REJECT> — one sentence why

  ### Punch list
  | # | Section of plan | Issue | Recommended change |
  |---|----|----|----|

  ### Analogous code coverage
  | Plan section | Analogous file | Pattern matched? | Gap |
  |----|----|----|----|

  ### Acceptance criteria coverage
  | AC | Where in plan | Covered? |
  |----|----|----|

  ### Risk notes (cross-repo, CLAUDE.md violations, memory hits)

Do NOT propose code. Do NOT generate a "revised plan" — the orchestrator
will apply your punch list and re-run review if needed.
```

After Codex returns:

1. Write the full Codex response to `<WORKTREE>/codex-reviews/step-6-qplan.md`.
2. Parse the verdict line:
   - `PASS` → write `Step 6 Plan Review: [DONE] Result: passed (codex: gpt-5.5 high)` to `phase2-progress.md` and continue.
   - `REVISE` → Claude reads the punch list, applies each change to `plan.md` (or per-repo files), then re-dispatches Step 6 codex review. Max 2 revision rounds; after that, escalate to the user.
   - `REJECT` → HALT the worker, surface the Codex verdict to the orchestrator, do not proceed to Step 7.
3. The punch list never directly edits code — it edits the plan only. Step 7 (Implement) starts from the revised plan file.

### Step 7.5 — Simplify (replaces the `code-simplifier:code-simplifier` Task)

Prompt body (preceded by the standard "you are a code simplifier" preamble from pipeline-steps.md §7.5):

```
You are reviewing this worktree as a code simplifier. Read SKILL.md from
~/.codex/skills/qclean (clean-code review) and ~/.codex/skills/qreuse
(reuse review) before writing your report.

Diff: <BASE_SHA>..<HEAD_SHA>
Run: git diff <BASE_SHA>..<HEAD_SHA>

Output exactly two sections:

## APPLIED SIMPLIFICATIONS
(list of edits you would make, with file:line and the exact diff hunk)

## RATIONALE
(per-edit, 1–2 sentences citing the qclean or qreuse rule)

Do NOT actually edit files. Claude will apply the patches; your job is to
identify them with high precision.
```

After Codex returns, Claude reads the report and applies the patches itself (Step 7.5.3 enforcement: simplifier suggestions MUST be applied, not just listed — see pipeline-steps.md §7.5.3).

### Step 8.1 — Superpowers Code Reviewer

Prompt body: take the existing pipeline-steps.md §8.1 prompt verbatim (which now contains the UUID resolution surface check — see "UUID resolution surface (NEW — post-{{JIRA_PROJECT_KEY}}-EX12)" in the prompt). Prepend:

```
You are running as a codex exec subprocess under qship's Phase 2.
Skills available via /skills: qcheck, qcheckf, qclean, qreuse, qcheckt.
Read CLAUDE.md at the repo root and ~/.claude/CLAUDE.md before reviewing.

IMPORTANT — explicit reinforcement of the UUID resolution check baked into
the §8.1 prompt body below: for every new UI surface in the diff, run

    git diff <BASE>..<HEAD> -- '*.jsx' '*.tsx' '*.js' '*.ts' \
        ':!**/dist/**' ':!**/build/**' ':!**/node_modules/**' \
        ':!**/*.min.js' ':!**/*.bundle.js' \
      | grep -E "resolve[A-Z][a-zA-Z]*Name|resolve[A-Z][a-zA-Z]*Value|renderResolvedValue|renderRuleValue"

If anything matches, flag a CRITICAL finding citing:
  (a) is the render gated on resolver.ready? (canonical: entityLookup.js:121
      exposes .ready; ResolvedRefCell.jsx + ResolvedSummaryView.jsx are the
      reference call sites);
  (b) does the loading state render a Mantine <Skeleton> per the canonical
      convention? (truncated-UUID placeholders are NOT the convention);
  (c) when .ready === true && resolver(id) === null — does the code keep
      the codebase convention of rendering the raw UUID, or has it
      regressed into a truncated placeholder?
  (d) does the Playwright harness mock the resolver hook? If yes, flag —
      mocked-hook tests cannot prove the .ready gate is wired correctly
      because mocks return synchronously (no loading window).

Combination of 'resolver(id) || id' + NO .ready gate + mocked-hook tests
= guaranteed UUID leak in production environments where the lookup is
unreachable. That's the {{JIRA_PROJECT_KEY}}-EX12 failure mode.
```

### Step 8.2 — Feature-Dev Code Reviewer

Same wrapper (including the explicit UUID-resolution reinforcement), with the §8.2 prompt body verbatim.

### Step 8.3 — Tests Reviewer (qcheckt)

```
Follow ~/.codex/skills/qcheckt/SKILL.md as your review checklist. Apply it
to every test added or edited in <BASE_SHA>..<HEAD_SHA>. Output findings in
the same Critical/Important/Minor sections that SKILL.md specifies.
```

### Step 8.4 — Spec Compliance Reviewer

Take the existing pipeline-steps.md §8.4 prompt body (which now contains the UUID resolution check at the end). Wrap with the same "you are running as a codex exec subprocess" preamble PLUS the explicit UUID-resolution reinforcement from §8.1 above. No skill dependency — the Jira ticket + diff are the inputs. Rationale for including a code-quality check in the spec-compliance reviewer: UUID leaks ship as AC violations ("display the entity's name" becomes "display the entity's id"), so this IS a spec-compliance concern even though the surface form is code quality.

### Step 9 — Bug Hunt (N parallel hunter slots, N from tier table §8.0)

For each hunter slot, dispatch one `codex exec` in parallel:

```
You are a bug hunter. Follow ~/.codex/skills/qbug/SKILL.md exactly. Focus
on the diff <BASE_SHA>..<HEAD_SHA>.

Specialty for this slot: <SLOT_SPECIALTY>
  (slot 1: logic errors, off-by-one, inverted conditions)
  (slot 2: silent failures, swallowed exceptions, missing error paths)
  (slot 3: race conditions, async timing, shared mutable state)
  (slot 4: edge cases, boundary conditions, null/empty/Decimal-zero,
           UUID-leak edge cases — see below)
  (slot 5: security — injection, auth bypass, data exposure)

UUID-leak edge cases (slot 4 mandatory addition — post-{{JIRA_PROJECT_KEY}}-EX12):
For any new UI surface rendering a UUID-bearing field (subject_id,
node_id, organization_id, attribute_value_id, policy_id, etc.) —
typically routed through a resolve*Name / resolve*Value helper — check:
  - {{PRIMARY_REPO_NAME}} unreachable / 401 the external auth provider / CORS preflight failure / network
    partition — does the user see raw UUIDs, or does the resolver.ready
    gate hold the render in a Mantine <Skeleton>? (Canonical pattern:
    ResolvedRefCell.jsx and ResolvedSummaryView.jsx; .ready attribute lives
    on the resolver function — see entityLookup.js:121.)
  - The org has more entities / nodes than the lookup hook's PAGE cap
    (default 500 in src/components/shared/entityLookup.js:20) — are
    out-of-page IDs rendered safely, or does the UI flash UUIDs?
  - Cross-tenant cache collision — viewing tenant B's policy while
    tenant A's resolver cache is still loaded — does the resolver
    return the wrong name, or a stale UUID fallback?
  - Empty-string resolver return vs null — does 'resolver(v) || v'
    treat '' as 'no result' and render the raw UUID, or does an empty
    string skip the fallback and render nothing?
  - Truncated-UUID placeholders ('Entity 00000000...') — flag any
    introduction. Codebase convention is <Skeleton> while loading,
    raw UUID after .ready === true; NOT a truncated placeholder.

Output: structured findings list per SKILL.md format. Do not propose fixes;
only identify bugs.
```

Each slot writes its own `codex-reviews/step-9-slot-<N>.md`. Claude merges them into the standard `qbug-raw-findings.md` consumed by Step 9.5 (dedupe) and 9.6 (top-K ranking).

### Step 10 — qbcheck (Bug Validation)

```
Follow ~/.codex/skills/qbcheck/SKILL.md exactly. Validate each finding in
qbug-topk-findings.md. For each finding output:

  Verdict: REAL | OVERSTATED | FALSE POSITIVE | OVERTHINKING
  Actual severity: Critical | High | Medium | Low | N/A
  Evidence: <quoted code + 20 lines of surrounding context>
  Action: FIX | DOWNGRADE | REJECT | DEFER

Same output table format as SKILL.md §"Validated findings table".
```

Claude reads the validated table and writes it into `phase2-findings.md` for Step 11 (Fix) to consume.

## Fallback contract — non-negotiable

If `codex exec` fails for a slot (non-zero exit, malformed JSON, refusal, or sandbox error), **fall back to the Claude Task subagent for that slot only** — don't abort the whole Phase 2. Log the fallback to `codex-reviews/fallback.log` with the slot number, the codex error, and the eventual Claude Task verdict. After 3 fallbacks in a single Phase 2 run, abort the codex override entirely and continue Phase 2 as if `REVIEWER=claude` was set — log a single `phase2-reviewer-degraded.flag` so post-run analysis sees the degradation.

## Reporting

Append to `phase2-progress.md` per step:

```
| 6 Plan Review | DONE (codex: gpt-5.5 high) | verdict=PASS — see codex-reviews/step-6-qplan.md |
| 7.5 Simplify | DONE (codex: gpt-5.5 high) | applied 4 patches from codex-reviews/step-7.5.md |
| 8.1 Reviewer | DONE (codex: gpt-5.5 high) | 2 Critical, 5 Important — see step-8-slot-1.md |
| 8.2 Reviewer | DONE (codex: gpt-5.5 high) | 1 Critical, 3 Important |
| 8.3 qcheckt  | DONE (codex: gpt-5.5 high) | 2 Important on test isolation |
| 8.4 SpecCmp  | DONE (codex: gpt-5.5 high) | all AC covered |
| 9 BugHunt    | DONE (codex: 3 slots gpt-5.5 high) | 7 raw findings → 4 after dedupe |
| 10 qbcheck   | DONE (codex: gpt-5.5 high) | 2 REAL, 1 OVERSTATED→DOWNGRADE, 1 FP |
```

Step 11 (Fix) reads `phase2-findings.md` exactly as it would under `REVIEWER=claude` — the contract that Step 11 consumes is unchanged.

## When NOT to use REVIEWER=codex

- Migration-heavy diffs (alembic chains, autogenerate noise). Step 8.5.1 stays in Claude regardless; if 50%+ of the diff is migrations the rest of Phase 2 is also marginal under codex — fall back to defaults.
- Tickets where the implementation itself was Codex (`provider=codex reviewer=codex`). Codex reviewing its own output collapses the diversity gain — the whole point of routing review to a different family is the second-opinion signal. Strongly prefer `provider=codex reviewer=claude` or `provider=claude reviewer=codex` over the all-codex combo.
- Any ticket where {{JIRA_PROJECT_KEY}}-EX01-style cross-repo enum / RLS / auth concerns dominate — the carve-outs from `PROVIDER=codex` apply equally to `REVIEWER=codex` since the model doesn't load the {{COMPANY_SLUG}} memory rules that would catch those.
