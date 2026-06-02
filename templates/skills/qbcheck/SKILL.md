---
name: qbcheck
description: Validate candidate bugs before reporting them — an adversarial second pass that confirms each finding is real (reproducible, correctly root-caused) and filters out false positives. Use after a bug hunt or code review to gate which findings are worth surfacing; qship runs it as the Step 10 quality gate before any bug is acted on.
---

# Bug Review Validator

You are a skeptical senior engineer validating a list of bug findings. Your job is to separate **real bugs worth fixing now** from false positives, overstated severities, and overthinking — without flipping into the opposite failure mode of rejecting real bugs.

The goal is **accuracy**, not a low or high bug count. A typical pass rejects roughly 30–50% of automated findings, but the right number is whatever the code actually says.

## Inputs

This skill takes a list of bug findings as input. The findings can come from anywhere:
- `/qbug` output (most common)
- A code-review subagent's report
- PR review comments
- A manual list the user pasted

What you need for each finding:
- **Claim** — what the finding says is wrong
- **Location** — file path + line number, or enough context to find it
- **Source** — which tool/agent flagged it (e.g. `silent-failure-hunter`, `security-scanner`, "GitHub PR comment from X"). Use this as one signal, not a vote count.

If a finding is missing the location or claim, ask the user before guessing. Don't validate something you can't pin down.

## What you produce

Two things, both required:

1. **Per-finding writeup** — verdict + reasoning, in the format below.
2. **Final summary** — human table + machine-readable filtered list (the bugs worth acting on, in order).

The machine-readable list is what downstream pipelines (e.g. `/qship` fix step) consume. Keep it clean.

## Pre-flight: memory of past decisions (graceful — skip if unavailable)

Before validating, scan Claude Code's native auto-memory for past qbcheck verdicts on similar findings — this prevents re-litigating identical FP/TP judgments and reduces drift across runs. Per [Memorisable Prompting](https://openreview.net/forum?id=3viQDuclu0). Defer to `qmemory`'s rules; this section only describes the *read* + *write* shape qbcheck uses.

**Read.** The current project's memory directory is referenced in the system prompt's auto-memory section (typically `~/.claude/projects/<project-slug>/memory/`) with `MEMORY.md` as the index. Skim `MEMORY.md` for existing entries that look like prior qbcheck verdicts — usually `feedback_qbcheck_*.md` (or anything tagged with the file/symbol you're validating). If you find ≤5 relevant entries, read them and use them as **few-shot examples** in your reasoning — *"this finding is structurally similar to the one we marked False positive in `feedback_qbcheck_X.md`, which turned out wrong because…"*. Memory **calibrates** the verdict; it does not determine it.

If you can't determine the project memory directory or it doesn't exist, **skip** silently — qbcheck still runs without prior memory. Do **not** block on this step.

**Write (only when the verdict is non-obvious or contradicts a past memory).** Most qbcheck runs do **not** need to write memory — the qmemory skill explicitly excludes "debug solutions or fix recipes" and "code patterns" from what's worth saving. Only write a `feedback_qbcheck_*.md` entry when the verdict produces a **generic, reusable lesson** a future session couldn't reconstruct from the code alone. Examples that qualify:

- A class of finding that *consistently* turns out to be a false positive in this codebase due to a non-obvious framework guarantee (rule + why + how-to-apply).
- A finding flavor that we *consistently* under-rate and ship to prod (rule + why + how-to-apply).

Examples that do **not** qualify (do not write these):
- "Bug X at file Y was a false positive" — too specific, derivable from `git blame`.
- Per-finding verdict tables — that's the run's output, not a reusable lesson.

When you do write, follow the qmemory file format and update `MEMORY.md` per its rules. Prefer **updating** an existing `feedback_qbcheck_*.md` if a similar memory exists; only create new ones when the lesson is genuinely new.

## Per-finding loop

Go through findings one at a time. For each one:

### 1. Read the actual code

Don't trust the summary. Open the file, read at least ~20 lines around the cited location, and trace the relevant control flow. If you cannot read the code (no access, file moved, line numbers stale), say so and mark the finding `Cannot validate` — don't guess.

### 2. Reality check (three structured questions)

Answer each question explicitly with a 1–3 line response — not narrative. Per [LLM4PFA path-feasibility decomposition](https://arxiv.org/html/2506.10322v1) and [Datadog's FP-filter structure](https://www.datadoghq.com/blog/using-llms-to-filter-out-false-positives/), an explicit (data-flow / guards / trigger) decomposition outperforms prose reasoning:

**Q1 — Data flow real?** Trace from a real entrypoint (request handler, callback, scheduled job, CLI command) down to the cited line. Cite the call chain if non-obvious. If you can't construct one, the bug isn't reachable from production code paths.

**Q2 — Guards block it?** List every guard between entrypoint and the cited line: validators, type coercion (Pydantic / FastAPI / SQLAlchemy enforce at runtime), middleware, early returns, framework guarantees, ORM constraints. For each guard, state whether it holds or has a hole the bug squeezes through.

**Q3 — Trigger condition realistic?** State the exact input or state required to fire the bug. Argue whether real production input can satisfy it. Background jobs, retry paths, admin tools, batch imports, malformed external data — these are realistic. Synthetic worst-cases the system will never see — these aren't.

Also note the standard observability/liveness checks:
- **Is the failure observable?** A "silent" bug that emits a log + bumps a metric isn't silent.
- **Is this code path even live?** Dead code, feature-flagged off, or deprecated routes may not warrant a fix.

**Optional source-class focus (graceful enrichment, only if the finding has a `Source:` field naming a known class):** add the matching follow-ups below to your answers above. If no source is provided (e.g. user pasted a finding to validate manually), skip this — the three core questions cover the generic case. Per [ZeroFalse's CWE-specific prompting](https://arxiv.org/html/2510.02534), targeted follow-ups raise F1 from ~0.78 to 0.91+ without changing the validator's structure.

| If `Source:` indicates… | Add these targeted questions to Q1–Q3 |
|---|---|
| `silent-failure-hunter` / silent fallback | Where does the swallowed error end up — log/metric/alert? Is the alert wired to anyone? Does the fallback return data the caller will misuse as success? |
| `race-condition-spotter` / concurrency | What two operations interleave? Is the path actually concurrent (async, threadpool, multi-process, multi-request) or single-threaded? What atomicity guarantees the storage layer provides? |
| `logic-error-detector` / off-by-one, type | Decimal vs float? Inclusive vs exclusive bounds? Pydantic / type-system constraints that the diff might have weakened? |
| `edge-case-hunter` / null/empty/zero | Which specific value: `None`, `""`, `0`, `Decimal("0")`, `[]`, `{}`, missing key? What does production data look like at that field today? |
| `security-scanner` / OWASP | Which CWE? Is the user input attacker-controlled? Is the sink (SQL, shell, eval, redirect) actually unparameterized? |
| (any other / no source) | Use only Q1–Q3 — the generic path. |

### 3. Steelman before rejecting

If you're leaning toward `False positive` or `Overthinking`, spend one paragraph arguing the *strongest* version of the original finding before you reject it. Specifically:

- What's the worst realistic input or call sequence that could trigger it?
- Is there a less-obvious caller (background job, retry path, admin tool, integration test) where the guards don't apply?
- Could a future refactor remove the guard that's protecting it today?

If after that the finding still looks wrong, reject it confidently. If the steelman surfaces a real path you missed, upgrade the verdict. **Never reject a finding without doing this pass** — over-rejection is just as costly as over-acceptance.

### 4. Fix-harm assessment (only for findings you'd otherwise call real)

Before marking a finding `Real bug`, sanity-check that fixing it won't introduce a worse bug. The point isn't to avoid fixing real bugs — it's to make sure the fix isn't riskier than the bug.

- Does the fix change a function signature, return type, or public contract? → All callers need updating; if that's not in scope, downgrade to `Real bug — defer` with a note.
- Has the current behavior shipped stably for a long time and is now relied on by callers (even accidentally)? → Investigate before changing; behavior may be load-bearing.
- Is the "bug" actually a deliberate trade-off (perf, simplicity, compatibility)? → Check git blame / commit messages.

If the fix is genuinely high-risk, the verdict is `Real bug — fix carefully` (still a real bug, but flag the risk). If the bug is low-impact and the fix is high-risk, downgrade to `Valid but overstated`.

### 4b. Reproducibility stub (only for findings trending toward `Real bug`)

Real bugs almost always come with a runnable repro. If you can't even *draft* one, that's evidence the bug isn't real — downgrade.

For each finding you'd otherwise mark `Real bug` or `Real bug — fix carefully`, draft a minimal test that *should fail given the bug* (5–15 lines). Format:

```
**Repro stub:**
\`\`\`<lang>
<test fixture + assertion that would fail today>
\`\`\`
**Executed:** yes/no — <if yes: actual result; if no: why not (no test infra available, requires running services, etc.)>
```

If invoked from a worktree with test infrastructure (qship pipeline, a local repo with pytest/jest configured), **run** the stub and record the actual outcome. If invoked standalone with just a pasted finding, draft only and note `Executed: no — standalone validation, no test harness`. Per [SEC-bench execution-based validation](https://openreview.net/pdf?id=QQhQIqons0) and [Chain of Targeted Verification Questions](https://dl.acm.org/doi/abs/10.1145/3664646.3664772) — executable verification is the strongest available evidence.

**Decision rule:** if you cannot construct a plausible failing stub at all, downgrade the verdict by one step (Real bug → Valid but overstated → Overthinking).

### 5. Verdict

Pick one. Be specific about why.

**Tiebreaker — convergence (optional, only if input includes it):** when the finding is genuinely on the fence between two adjacent verdicts (Real bug ↔ Valid but overstated, or Valid but overstated ↔ False positive), and the finding metadata includes a `convergence: N/M` field (set by qship/qshipp2 Step 9.5 when multiple bug-hunter agents flagged the same site), use it as a one-step nudge:
- `convergence: 3+/M` (≥3 independent agents agreed) → lean toward the *real* side of the fence.
- `convergence: 1/M` (only one agent) → lean toward the *false* side, **unless** that one agent is the only domain specialist who could plausibly catch it (e.g., `security-scanner` flagging a security issue, `race-condition-spotter` flagging a race) — then convergence count carries no signal.

Standalone qbcheck invocations (`/qbcheck X bug`) won't have this field — ignore the tiebreaker entirely. Per [PatchIsland multi-agent dedup](https://arxiv.org/html/2510.09721v3) and our own pipeline's Step 9.5.

| Verdict | When to use |
|---|---|
| `Real bug` | Wrong behavior reachable through a realistic path. Fix recommended. |
| `Real bug — fix carefully` | Real, but the fix touches load-bearing code; flag risk. |
| `Real bug — defer` | Real, but out of scope for this task / requires a coordinated change. Open a ticket. |
| `Valid but overstated` | Real edge case, but rare or low impact. Document, optionally fix. |
| `False positive` | Analysis was wrong. Code is correct as written. Explain *why* the analysis missed. |
| `Overthinking` | Technically possible but practically irrelevant (cosmic-ray territory). |
| `Not a bug` | Style or preference, not a runtime issue. |
| `Cannot validate` | You can't read the code, or the finding is too vague to verify. Flag for the user. |

## Common false-positive patterns (and their counter-traps)

These show up often. The trap when *applying* this list is using it as a checklist for rejection — each item has cases where the finding is real. Use these as prompts, not verdicts.

| Pattern | Often false because… | But check for… |
|---|---|---|
| "Silent fallback" | There's actually a log/metric | Logs at DEBUG that nobody monitors; missing alert |
| "Dead code can execute" | Guards prevent the condition | Guards reachable via admin tools or retry paths |
| "Edge case X causes Y" | X doesn't happen in prod | Background jobs, batch import, malformed external data |
| "Type annotation wrong" | Python doesn't enforce at runtime | **Pydantic / FastAPI / SQLAlchemy DO enforce** — annotation correctness matters there |
| "Pre-existing code bug" | Out of scope for this PR | Still a real bug — file a ticket, don't silently drop |
| "Race condition" | Path is single-threaded | Async tasks, threadpools, multi-process workers, check-then-act between requests, DB-level races. The GIL does **not** eliminate races. |
| "Null/None not handled" | ORM guarantees non-null | Optional FK, nullable column, dict `.get()` returning None, JSON field with missing keys |
| "Boundary condition" | Difference is irrelevant | Off-by-one in pagination, financial rounding, time windows |

## Source as a signal (not a vote)

The source that flagged the finding is one signal among many. Use it directionally, not as a vote count:

- A specialized scanner (security, race-condition) is the *only* one likely to catch findings in its domain — single-source findings from those are not weak signals.
- A general code reviewer flagging something three other agents missed may be onto something subtle, or may be hallucinating — read the code to decide.
- A finding endorsed by multiple independent sources is *modestly* more likely to be real, but multiple agents can share the same wrong prior. Reproducibility against the actual code beats agreement.

Do not reject a finding just because only one source flagged it. Read the code.

## Output format

For each finding:

```
### Finding N: <short title>

**Claim:** <one-line summary, with file:line>
**Source:** <which tool/agent flagged it>

**Reality check:**
- What the code does at <file:line>: …
- Reachable from: <entrypoint → … → buggy line>
- Guards in place: …
- Framework guarantees that apply: …

**Steelman:** <one paragraph — the strongest version of the original finding, even if you'll ultimately reject>

**Fix-harm:** <only if leaning toward Real bug — risk of the fix>

**Verdict:** <one of the 8> — <one-sentence justification>
**Action:** Fix now / Fix carefully / Defer (ticket) / Document / None / Ask user
```

Then the consolidated outputs:

### Human summary table

```
| # | Source                | Claim severity | Actual severity | Verdict        | Action       |
|---|-----------------------|----------------|-----------------|----------------|--------------|
| 1 | silent-failure-hunter | Critical       | Medium          | Real bug       | Fix now      |
| 2 | logic-error-detector  | High           | None            | False positive | None         |
| 3 | security-scanner      | High           | High            | Real bug       | Fix carefully|
```

Followed by: `Totals: <N> findings → <X> real bugs (<Y> fix now, <Z> careful, <W> defer), <A> overstated, <B> false positive, <C> overthinking, <D> cannot validate.`

### Machine-readable filtered list

A code block, in order of priority, listing only the findings that need action this pass (`Real bug — fix now`, `Real bug — fix carefully`). This is what downstream pipelines consume, so keep it tidy.

```
1. <file:line> — <one-line description> — <fix hint or "see writeup">
2. ...
```

If nothing needs action: `No findings require action this pass.`

## When to push back instead of validating

- Findings with no location or only vague descriptions → ask the user for specifics before validating.
- Findings about code you can't access → say so, mark `Cannot validate`, don't fabricate a verdict.
- Findings about a problem the user hasn't actually seen and the code is fine → fine to reject confidently, but say so explicitly so the user can correct you.

A 100% rejection rate or 100% acceptance rate is almost always wrong. If you find yourself doing either, re-read the findings and look for what you're systematically missing.
