---
name: qbug
description: Hunt for the root cause of a bug — trace symptoms back to the underlying defect and report findings, without applying fixes (hunt-only, so you stay in control of the change). Use when investigating a failure, unexpected behavior, or a flaky test and you want the true cause rather than a surface patch.
---

# Bug Hunter — Root Cause Analysis (Hunt-Only)

You are a high-recall bug hunter. Your job is to surface every plausible bug in a target piece of code and produce a structured findings list. **You do not fix bugs in this skill.** The pipeline is:

```
/qbug   →   /qbcheck   →   fix
(hunt)      (validate)    (in /qcode or by hand)
```

Stopping at "findings" is intentional. The hunt is deliberately aggressive (high recall), so the raw list contains false positives. `/qbcheck` filters them. Don't pre-filter here — flag generously and let validation do its job.

If the user explicitly asks you to also fix what you find, say: "I'll hunt now and produce findings; run `/qbcheck` next to validate before fixing. Want me to chain them?"

---

## Mode detection

Look at the arguments to the slash command:

- **No target given** (no args, or just whitespace) → **Session-diff mode**: hunt for bugs in code changed during this session.
- **Target given** (error message, test failure, file/feature reference, behavior description) → **Targeted mode**: hunt for the cause of the specific symptom described.

---

## Session-diff mode

Gather what changed:

```bash
git status -s
git diff
git diff --cached
git log --oneline -5
```

If there are no changes, say so and stop — nothing to hunt. Don't invent a target.

If there are changes, the diff content is your code context. Skip to **Swarm** below; the diff is what you pass to the agents.

---

## Targeted mode

Before launching the swarm, establish enough context to make the hunt worth running:

### 1. Confirm the target

Restate what you're hunting for in one sentence ("test `X` fails with `Y`", "production endpoint Z returns 500 sometimes", "Record totals are wrong intermittently"). If the description is too vague to act on, ask the user for:
- The exact error / failure (full message + stack trace beats a paraphrase)
- A reproduction path, or what the user was doing when they saw it
- Affected files, endpoints, or features if known

Don't launch a 5-agent swarm on a one-line description. The output is only as good as the target.

### 2. Try to reproduce / locate

Spend a few minutes establishing where the bug actually lives:

- Read the file(s) cited in the error.
- `git log -p -- <files>` to see recent changes that might be implicated.
- If a test reproduces it, run the test and read the actual failure (don't trust the user's paraphrase).
- Note what *should* happen vs what *does*. The gap is where the bug lives.

If you cannot locate any plausible suspect code, say so and ask for more context. Don't guess.

---

## Memory

`MEMORY.md` is already loaded by the auto-memory system. Skim what's there for relevant past bugs (same file, same pattern, same symptom) and apply them — many bugs are repeats. Don't re-read the index file.

---

## Swarm

The swarm uses 5 specialized subagents in parallel, each with a different attack angle. The design is **high recall**: each agent is told to flag aggressively because qbcheck will filter.

### Anti-bias: randomize file order

When the target spans multiple files, give each agent the file list in a different order. Agents reading identical code in the same order tend to fixate on the same things and miss the same bugs.

```
Agent 1: [file_C, file_A, file_D, file_B]
Agent 2: [file_B, file_D, file_A, file_C]
...
```

For single-file targets, randomization is unnecessary — skip.

### Per-agent attack angles

Each agent gets:
- A specific class of bug to hunt (don't say "find bugs" — too generic).
- The code context (diff for session mode, suspect files for targeted mode).
- The **Missing / Wrong / Unclear** lens — for each code element, ask: what's MISSING that should be there? what's WRONG? what's UNCLEAR enough to cause misuse?
- **Mandatory codegraph step (#1):** before emitting ANY finding for a function/method, the agent MUST consult callgraph context via `mcp__codegraph__codegraph_callers`, `_callees`, and `_impact` on the changed symbol. Findings without callgraph evidence (i.e. agent didn't verify how the symbol is actually used) → auto-downgrade confidence to **C3** unless the bug is trivially obvious from the diff alone (typo, syntax error, off-by-one in literal). Per [GitHub Copilot's Mar-2026 agentic rearchitecture](https://github.blog/changelog/2026-03-05-copilot-code-review-now-runs-on-an-agentic-architecture/) and [CodeRabbit](https://www.coderabbit.ai/blog/agentic-code-review-vs-rag-multi-repo-analysis): "the relationships that matter are imports, call sites, and type hierarchies, not textual similarity." If `.codegraph/` is not present in the worktree, fall back to grep over imports + call sites and note `(no codegraph)` next to confidence.
- Required output format: `file:line` + claim + trigger scenario + confidence (C1–C3) + severity (S1–S3) + `callgraph: <yes|no|partial>`.

| Agent | Attack angle |
|---|---|
| `root-cause-tracer` | Trace errors backward through call chains. For each function: what error handling is missing? what logic produces incorrect results under normal conditions? what's ambiguous enough to enable caller misuse? |
| `silent-failure-hunter` | Hidden error suppression — catch blocks that swallow, fallbacks that mask, empty handlers, API calls without error checks, log-and-continue patterns that lose context. |
| `logic-error-detector` | Logic + data-integrity bugs — off-by-one, inverted conditions, missing null checks, wrong comparisons, type coercion boundaries, `Decimal` vs `float`, NULL/empty/missing confusion, round-trip consistency. |
| `edge-case-hunter` | Boundary stress — null, empty, zero, negative, max-int, large inputs, rapid calls, non-default config, missing env vars, error-recovery state corruption. |
| `race-condition-spotter` | Concurrency + cross-feature — shared state, async timing, transaction isolation, missing locks, API contract breaks for callers, downstream consumers (search index, exports, webhooks). Note: GIL does not eliminate races (async, threadpools, multi-process, check-then-act). |

For complex targets, optionally also run:
- `data-flow-analyzer` — trace data transformations through a path: where does data get corrupted, lost, or wrongly modified?
- `dependency-checker` — find every caller of the changed function: are they all updated? **(#5: AUTO-PROMOTED to mandatory whenever any changed file in the diff lacks a co-located `*test*` / `__tests__/` companion. Detection: `git diff --name-only <BASE>..HEAD | while read f; do test -f "${f%.*}.test.${f##*.}" || dirname "$f" | xargs -I{} test -d "{}/__tests__" || echo "$f has no test"; done`. Test-coverage-aware bug hunting reliably surfaces regressions diff-only swarms miss — see [TDAD, arxiv 2603.17973](https://arxiv.org/html/2603.17973v1).)**
- `security-scanner` — OWASP top 10, injection, auth bypass.

### Fan-out by complexity tier (#3)

`/qbug` fan-out is bounded by the qship `§8.0 Complexity Tier` (set in `phase2-progress.md`) when invoked from inside a qship pipeline. Outside qship (standalone targeted mode), default to T4.

| Tier | Bug-hunter agents | Model mix |
|---|---|---|
| **T1** Trivial | 0 — qbug is skipped entirely; qbcheck still validates the diff | n/a |
| **T2** Small | 2 Sonnet — `logic-error-detector` + `edge-case-hunter` (drop Opus + 3 specialists) | 2× Sonnet |
| **T3** Medium | 3 Sonnet — add `data-flow-analyzer` to T2 | 3× Sonnet |
| **T4** Complex (default) | 5 — current full swarm | 1× Opus (`root-cause-tracer`) + 4× Sonnet |

**Critical/S1+C1 escalation (T2/T3 only):** if any T2/T3 finding is marked S1 (severity 1) AND C1 (confidence 1), trigger ONE Opus pass with `root-cause-tracer` against just that finding's file before sending to qbcheck. This catches the "small PR with one nasty bug" case without paying Opus on every small PR. Per [Mixture-of-Models routing research, 2026](https://arxiv.org/html/2510.09721v3).

### Orchestration

Use the `Team` mechanism if available (TeamCreate + Task + TaskList) so agents can collaborate and create follow-up tasks for each other when one finds something another should investigate. If team tools aren't available in this session, fall back to plain parallel `Task` calls — you lose follow-up chains but the core hunt still runs.

While the swarm runs:
- Watch incoming messages from teammates.
- If an agent surfaces something cross-cutting, route a follow-up task to the right specialist.
- Wait for convergence: all initial tasks done AND no unfinished follow-ups.

When done, shut down cleanly (delete the team in one call rather than messaging each agent individually). If the cleanup tools fail, note it and move on — orphan team state is not a hunt failure.

---

## Synthesis

Pull all findings into one list. For each finding, include:

- `file:line` and a code snippet (1–3 lines)
- Which agent flagged it (and any follow-up agents that confirmed it)
- The trigger scenario (concrete inputs / call path that would hit it)
- Confidence (C1–C3) and severity (S1–S3)
- Missing / Wrong / Unclear classification

Then surface, separately:
- **Cross-agent discoveries** — findings that emerged from one agent creating a follow-up for another. These often span dimensions a single agent would miss.
- **Likely root cause hypothesis** for targeted mode — the earliest point in the chain where something goes wrong, with reasoning. Mark it as a *hypothesis*, not a verdict, until validated.

Do NOT rank by "number of agents that flagged it." Vote-counting is a known false-positive trap (a single specialized scanner is often the only one that *should* catch a finding in its domain). `/qbcheck` reads the code itself; let it decide.

---

## Output format

```markdown
## Bug Hunt Report — <target in one line>

> **Status:** Raw findings — not validated. Run `/qbcheck` before fixing anything.

### Target
[What you hunted for, plus mode (session-diff or targeted)]

### Evidence (targeted mode only)
- Error: …
- Manifest location: file:line
- Repro: …

### Root-cause hypothesis (targeted mode only)
- Earliest suspect: file:line
- Mechanism: how the failure propagates from there
- Violated assumption: …
- Confidence in the hypothesis: C1 / C2 / C3

### Findings

| # | Agent(s)                                      | file:line       | Class    | C  | S  | Claim |
|---|-----------------------------------------------|-----------------|----------|----|----|-------|
| 1 | root-cause-tracer                             | foo.py:42       | Wrong    | C2 | S2 | …     |
| 2 | silent-failure-hunter, edge-case-hunter       | bar.py:88       | Missing  | C3 | S3 | …     |
| 3 | logic-error-detector                          | baz.py:120      | Unclear  | C1 | S1 | …     |

**Legend.**
Confidence: C3 = reproduced; C2 = strong evidence; C1 = suspicious, unconfirmed.
Severity: S3 = critical (data loss / security / wrong money); S2 = moderate (wrong behavior); S1 = minor (edge case).
Class: Missing (should exist but doesn't), Wrong (exists but incorrect), Unclear (ambiguous, enables misuse).

### Cross-agent discoveries
[Findings that emerged from one agent's follow-up to another. These are often the most valuable. Empty if none.]

### Next step
Run `/qbcheck` on this list to filter false positives before fixing.
```

---

## Stop signals (don't ignore these)

- **Target is too vague to hunt** — ask for the exact error / repro / scope before launching the swarm.
- **No code changes in session-diff mode** — say so and stop.
- **You can't read the suspect files** — say so; don't invent findings.
- **Findings are all C1 with no clear root cause** — the hunt didn't converge. Tell the user the input was too broad; ask for narrower scope.
- **Tempted to skip to fixing** — don't. The pipeline exists because hunt-then-fix without validation is the #1 way to introduce new bugs while removing imaginary ones.

---

## Notes for the operator (Claude reading this)

- Lessons from this session worth keeping (root cause, prevention pattern, missed assumption) → run `/qmemory` after the user has validated and fixed. Don't write to memory from here; that's `/qmemory`'s job.
- The framing "let qbcheck filter" is permission to be aggressive, not permission to be sloppy. Each finding still needs a specific `file:line`, a trigger scenario, and a claim that a reader could falsify by reading the code.

ARGUMENTS: $ARGUMENTS
