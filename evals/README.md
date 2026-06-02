# qship evals

A lightweight **behavioral** eval harness for the qship pipeline — the layer the
CI gates *don't* cover. CI checks that skills are well-formed (syntax,
placeholders, install, secrets). These evals check that the pipeline still
*behaves* well after a prose change: does it plan properly, cover the acceptance
criteria, produce real test evidence, and open a complete PR?

Why this exists: a one-word edit to a review skill can silently degrade output
quality, and nothing structural would catch it. The 2026 norm for prompt/agent
systems is golden-set + LLM-as-judge regression testing in CI
(see the project README's research notes). This is the minimal honest version of
that for a markdown-skill plugin.

## The model

```
fixture ticket  →  pipeline run (in a sandbox repo)  →  artifacts  →  LLM-as-judge  →  score
```

- **Fixtures** (`fixtures/*.md`) are tracker-agnostic spec tickets (the same
  shape qship's `tracker = none` mode consumes). Each declares acceptance
  criteria and an `## Expected pipeline behavior` block the judge scores against.
- **Rubric** (`rubric.md`) defines the scoring dimensions and the pass bar.
- **Judge** is `claude -p` reading the rubric + the fixture's expectations + the
  produced artifacts, emitting per-dimension scores as JSON.
- **Results** land in `results/` (gitignored).

## Running it

```bash
# 1. Validate the scaffold — no tokens, no claude. This is what CI runs.
bash scripts/eval.sh --check

# 2. Score artifacts a pipeline run already produced (needs claude):
bash scripts/eval.sh --judge --fixture 001-add-list-endpoint \
     --artifacts /path/to/state/worktrees/EVAL-001

# 3. Full loop — drive the pipeline in a sandbox, then judge (opt-in, spends
#    tokens; requires claude + an installed qship + a throwaway repo):
QSHIP_EVAL_EXEC=1 bash scripts/eval.sh --run --repo /path/to/sandbox-repo
```

`--run` without `QSHIP_EVAL_EXEC=1` prints the plan and exits (a dry run) so you
never spend tokens by accident.

## What CI does (and deliberately doesn't)

CI runs **`--check` only**: it keeps the fixtures and rubric from rotting. It
does **not** run the full behavioral eval — that needs API credentials, a
sandbox repo, and real token spend, which would make CI slow, flaky, and costly.
Full evals are an opt-in local / pre-release step. See
[`../docs/TESTING-SKILLS.md`](../docs/TESTING-SKILLS.md).

## Adding a fixture

Copy an existing file in `fixtures/`, keep the three required headings
(`# <title>`, `## Acceptance Criteria`, `## Expected pipeline behavior`), and use
generic domain language only (no real company / customer / product names — the
forbidden-string lint scans this directory).
