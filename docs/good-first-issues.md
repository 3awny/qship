# Good first issues (seed list)

Ready-to-file starter tasks for new contributors. After the repo is public, the
maintainer pastes these into GitHub Issues and labels them `good first issue` +
`help wanted`. Each is scoped to be completable in one focused sitting and to
teach part of the contribution workflow. Keep this file in sync as items ship.

> New here? Read [`../CONTRIBUTING.md`](../CONTRIBUTING.md) and
> [`TESTING-SKILLS.md`](TESTING-SKILLS.md) first. qship ships a lean
> **21-skill pipeline** — every skill is reachable from `qship`/`qshipmaster`,
> so changes should preserve that (don't add a skill the pipeline never calls).

---

### 1. Add a UI-touching eval fixture
**Why:** the current fixtures (`evals/fixtures/`) are backend-only. A UI fixture
exercises the Phase-3 browser-evidence path (`qe2etest` → `qmanualt`).
**Do:** Add `evals/fixtures/004-*.md` following the existing three (three required
headings, generic domain only). **Verify:** `bash scripts/eval.sh --check`.
**Files:** `evals/fixtures/`. **Difficulty:** ⭐

### 2. Document each hook's block reason in `docs/HOOKS.md`
**Why:** when a hook blocks a tool call, users want to know which artifact is
missing and how to satisfy it.
**Do:** For each script in `templates/skills/*/hooks/`, add a row to
[`HOOKS.md`](HOOKS.md): hook name → what it blocks → how to unblock.
**Files:** `docs/HOOKS.md`. **Difficulty:** ⭐ (doc-only, great first PR)

### 3. Add `--version` to `setup.sh`
**Why:** users and bug reports benefit from a version string.
**Do:** Read the version from `CHANGELOG.md`'s top heading (or a `VERSION` file)
and print it on `setup.sh --version`. **Verify:** `bash -n setup.sh`; run it.
**Files:** `setup.sh`. **Difficulty:** ⭐⭐

### 4. Make the `tracker = none` quickstart copy-pasteable in the README
**Why:** lots of evaluators will try qship without Jira first.
**Do:** Add a short "Try it with no tracker" snippet to the README using a local
spec file (point at an `evals/fixtures/` file as the example ticket).
**Files:** `README.md`. **Difficulty:** ⭐ (doc-only)

### 5. Trim an oversized SKILL.md with progressive disclosure
**Why:** Anthropic's skill guidance recommends a SKILL.md body < 500 lines, using
progressive disclosure (move long examples into a `references/` file and leave a
pointer). Check which of the 21 skills exceed it: `find templates/skills -name SKILL.md | xargs wc -l | sort -rn | head`.
**Do:** Pick one over-long skill, move rarely-needed detail into
`templates/skills/<name>/references/` and leave a one-line pointer. **Don't change
behavior.** **Verify:** `bash scripts/validate-placeholders.sh`; render with
`setup.sh` into a scratch `SKILLS_ROOT` and confirm the section still reads.
**Difficulty:** ⭐⭐

### 6. Add a smoke test that every installed skill is pipeline-reachable
**Why:** the repo's invariant is "ship only what `qship`/`qshipmaster` invoke."
A small CI check could grep the pipeline's invocation edges and fail if an
installed skill is never referenced (guards against re-introducing dead skills).
**Do:** Add a `scripts/check-skill-closure.sh` + a CI step. **Difficulty:** ⭐⭐⭐

---

**Maintainer note:** label these `good first issue` + `help wanted`; for the
SKILL.md-trim issue, ask the contributor to confirm they rendered + read the
output, since behavior must not change.
