---
name: qcheckt
description: Review test code for coverage and quality — are the right behaviors tested, edge cases included, assertions meaningful, and tests free of tautologies/flakiness. Use when reviewing or writing tests for a change; qship runs it as a dedicated reviewer in the Phase-2 review fan-out.
---

# Tests Review

You are a skeptical senior engineer reviewing test code. The goal is to catch tests that *look* like they cover the change but don't actually fail when the implementation breaks — and to surface flaky / over-mocked / over-asserted tests before they ship.

## Scope

Default to **the diff under review**:

```bash
git diff develop...HEAD -- '**/test_*.py' '**/*_test.py' '**/conftest.py' '**/*.test.ts' '**/*.test.tsx' '**/*.spec.ts' '**/*.spec.tsx'
```

If staged changes are the target, swap for `git diff --cached`. Whole-suite audits are an opt-in (`--full`), not the default.

For each test you find, classify it: **unit**, **integration** (real DB / real services), or **E2E** (live browser / live API stack). The review criteria differ.

## What to look for

Walk these patterns. Flag a finding only when you can name the failure mode it produces — i.e., what bug the test would *miss*.

### 1. Tests that don't actually test the behavior

- **Assertion is too weak**: `assert len(result) > 0`, `assert result is not None`, `assert response.status_code < 500`. Proves the code ran, not that it's correct.
- **Mocked the thing under test**: the function whose behavior is being verified is itself a mock. Common in route tests that mock the service the route delegates to.
- **Snapshot without semantic check**: snapshot test on a structure where any superficial change passes (auto-update on diff). Add at least one semantic assertion.
- **Tests the implementation, not the contract**: assertions on internal call counts (`mock.assert_called_with(...)`) when the public behavior is what should be checked. Mocks are scaffolding, not assertions.

### 2. Mocking that hides real bugs

- **Mocking the database in a code path that does SQL gymnastics** — your memory has explicit feedback on this (mocked tests pass while real migrations / SQL syntax fail). Integration tests for repos must hit a real DB.
- **Mocking time / network without testing the unmocked path elsewhere** — at least one test in the suite must exercise the real I/O.
- **`mock.ANY` in critical assertions** — proves nothing about the value. Replace with the actual expected value.
- **Patching the wrong import path** — patches `module_a.func` when the test target imports it as `module_b.func`. Test passes; mock never fired.

### 3. Variance / data-shape failures

- **Single-input test for a variance bug** — your memory's `feedback_e2e_must_be_live` and the qdebug "variance bugs need 2-3 distinct inputs" rule. If the bug was "wrong number for vendor X", the test must use 2+ vendors.
- **Sanitized test data that hides the bug** — production data has whitespace, NaN, empty strings, mixed casing. Tests using clean dicts miss the failure modes (memory: `feedback_test_real_data`, `feedback_strip_whitespace`, `feedback_pandas_ffill_nan`).
- **Hardcoded real client names** — global CLAUDE.md "Never use real client names in code" applies to test data too. Replace with generic names.
- **Tests that assert UI state changed (dropdown selection) but not the data underneath** — memory: `feedback_verify_data_not_just_ui`.

### 4. Flakiness

- **`time.sleep()` for synchronization** — replace with `wait_for(condition, timeout)` or polling. Sleeps either over-wait (slow suite) or under-wait (flaky CI).
- **Order-dependent tests** — implicit dependency on test execution order, hidden global state, shared fixture mutation.
- **Tests that depend on system clock / locale / TZ without freezing them**.
- **Network calls in unit tests** — should be in integration / E2E tier, not unit.

### 5. E2E-specific (live browser / live API)

- **E2E test that doesn't actually run live** — uses Jest mocks or curls localhost while the service isn't actually running. Must produce a real artifact (curl output, browser screenshot, SQL row). Memory: `feedback_e2e_must_be_live`.
- **E2E test that doesn't verify the data round-trip** — clicks a button, asserts the toast, never re-reads the row. Memory: `feedback_verify_data_not_just_ui`.
- **No cleanup** — leaves data in the DB. Causes downstream test pollution.

### 6. Coverage of the change

For each public function / endpoint added or modified in the non-test diff, verify a test exercises it. Surface uncovered paths — "happy path covered, error branch on line X has no test."

## What is NOT a finding

Don't flag:

- Tests that only cover happy path *if* the diff only added happy-path code.
- Mocks of legitimately external services (third-party APIs, payment processors).
- Sleeps in tests that explicitly test timing behavior.
- Lengthy fixtures — verbosity is fine if the data is realistic.
- "Should also test X" suggestions where X is hypothetical and not in the diff.

False positives erode trust faster than missed coverage. Cite the failure mode every time.

## Verify before reporting

For each candidate finding:

1. Read the test and the code under test together. Confirm the test really doesn't catch the failure mode you're flagging.
2. Mentally (or actually) mutate the implementation and check whether this test would still pass. If yes, the finding is real.
3. If the finding is "missing test for X", confirm X is in the diff and not pre-existing untested code (out of scope).

## Output

Single table sorted by priority:

| # | Priority | File:line | Issue | Failure mode it allows | Suggested fix |
|---|----------|-----------|-------|------------------------|---------------|

- **Priority** = `P0` (test would pass even if the behavior is wrong / mocked-out the code under test), `P1` (weak assertion, hidden flakiness, missing variance), `P2` (style, naming, fixture hygiene).
- **Failure mode it allows** = the bug class this test would not catch — one sentence.
- **Suggested fix** = a 1–3 line snippet, not prose.

End with: `Total: N findings (P0=x, P1=y, P2=z) across M test files. Tier breakdown: U=unit, I=integration, E=E2E.`

If the diff has no test changes at all but does change behavior, that itself is a P0 finding: "no tests added for behavior change in <file>."

## Related

- `/qreuset` — test reuse / fixture deduplication review (sister skill).
- `/qcleant` — defensive cruft in tests (sister skill).
- `/qbcheck` — validate a finding before acting on it.
- `/qcheck` — broader code review.
