# qship eval rubric

The judge scores a pipeline run against these dimensions. Each is **0–5**.
Score strictly: 5 means "a senior engineer would sign off without comment", 3
means "acceptable but with gaps", 0 means "absent or wrong".

## Dimensions

| # | Dimension | What 5 looks like |
|---|---|---|
| 1 | **Plan quality** | A concrete, ordered plan grounded in the actual codebase (named files/functions), not a generic restatement of the ticket. |
| 2 | **AC coverage** | Every acceptance criterion in the fixture is addressed by the implementation and referenced in evidence. None silently dropped. |
| 3 | **TDD evidence** | A failing test was written first, then made to pass — visible in the test artifacts, not asserted after the fact. |
| 4 | **Review thoroughness** | The review phase surfaced real issues (or credibly confirmed there were none); findings were verified, not hand-waved. |
| 5 | **Phase-3 evidence** | Concrete observable artifacts per acceptance criterion (curl + status, SELECT output, or a Playwright trace) — not "covered by unit tests". |
| 6 | **PR completeness** | The PR description maps changes to ACs, lists test evidence, and would be mergeable; CI considerations addressed. |
| 7 | **No skipped steps** | No phase gate was bypassed; nothing was declared done while a required artifact was missing. |

## Pass bar

- **PASS** — mean ≥ **4.0** AND no single dimension < **3**.
- **WEAK PASS** — mean ≥ 3.5 with at most one dimension at 2 (note it).
- **FAIL** — otherwise.

A regression is any drop in mean ≥ 0.5 vs the previous recorded run for the same
fixture, OR any dimension crossing from ≥3 to <3.

## Judge output contract

The judge must emit ONLY a JSON object:

```json
{
  "fixture": "<id>",
  "scores": { "plan": 0, "ac_coverage": 0, "tdd": 0, "review": 0,
              "phase3_evidence": 0, "pr_completeness": 0, "no_skipped_steps": 0 },
  "mean": 0.0,
  "verdict": "PASS | WEAK_PASS | FAIL",
  "notes": "<2-4 sentences citing the specific artifact that drove each low score>"
}
```
