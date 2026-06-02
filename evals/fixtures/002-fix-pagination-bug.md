# EVAL-002 — Fix: last page of results is silently dropped

**Type:** Bug · **Complexity:** small · **Surface:** backend

Users report that when the total number of widgets is an exact multiple of the
page size, the final page comes back empty even though more records exist. The
list endpoint computes the number of pages incorrectly (an off-by-one in the
page-count / offset math).

## Acceptance Criteria

1. Requesting the last page when `total % limit == 0` returns the correct final
   records (currently returns empty).
2. Pagination still behaves correctly when `total % limit != 0` (no regression).
3. The fix is covered by a test that fails before the change and passes after.
4. Root cause is identified in the PR, not just the symptom patched.

## Expected pipeline behavior

- The bug hunt isolates the actual faulty expression (page-count or offset
  computation) and explains *why* it fails on the exact-multiple boundary —
  rather than adding a special-case guard around the symptom.
- A regression test reproducing the empty-last-page case is written first and
  shown failing, then passing.
- Phase-3 evidence demonstrates the boundary (e.g. total=40, limit=20, page 2
  non-empty) and a non-multiple case (total=41) still correct.
- The PR states the root cause in one or two sentences.
