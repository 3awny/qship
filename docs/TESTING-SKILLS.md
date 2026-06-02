# Testing a skill change

Skills are markdown prose, so "does it work?" can't be answered by a unit test
alone. Here's how to gain confidence before opening a PR — fastest checks first.

## 0. Full install smoke test (simulate a brand-new user)

`bash scripts/smoke-test.sh` runs a complete fresh install into a **throwaway
`$HOME`** (your real `~/.claude` is untouched) and asserts: setup.sh succeeds,
exactly the 21-skill pipeline renders, zero unfilled `{{PLACEHOLDERS}}`,
`repos.json` is valid, `setup.sh --check` runs, and `uninstall.sh` cleans up.
Safe to run repeatedly. Pass `CONFIG=path/to/answers.json` to test with real
answers instead of the shipped example.

This covers the **install layer** only. A true end-to-end `/qship <ticket>` run
needs Claude Code + the 5 companion plugins + a tracker (or a `tracker=none`
local spec) — the script prints those exact next steps at the end.

## 1. Structural checks (seconds, no tokens) — always run these

```bash
bash scripts/validate-placeholders.sh   # every {{TOKEN}} is declared in config.example.json
bash scripts/check-no-local-leak.sh      # none of YOUR onboarded values leaked into a tracked file
bash scripts/eval.sh --check             # eval fixtures + rubric are well-formed
bash -n setup.sh && bash -n uninstall.sh # shell syntax
# if you touched a hook:
bash -n templates/skills/<skill>/hooks/<hook>.sh
```

CI runs all of these on your PR. They catch malformed skills, undeclared
placeholders, and leaked local values — but **not** behavior.

## 2. Render and read the rendered output

Your edit is a *template*. Render it the way a user would and read the result:

```bash
bash setup.sh --dry-run                  # shows what would render, no writes
# or render for real into a scratch location:
SKILLS_ROOT=/tmp/qship-test bash setup.sh --config evals/sample-answers.json   # if you have a sample
ls /tmp/qship-test/<skill>/
```

Check that no `{{PLACEHOLDER}}` survived and the prose reads correctly for the
config you rendered with (e.g. `tracker = none`, single-repo).

## 3. Smoke-test the behavior (the real test — needs claude + a sandbox repo)

Use a throwaway repo and `tracker = none` so no Jira/Atlassian is required:

```bash
# Install your edited skills into a scratch root:
SKILLS_ROOT=/tmp/qship-test bash setup.sh        # answer 'none' for the tracker
# Drive the skill against a sandbox repo using a local spec file:
cd /path/to/sandbox-repo
claude   # then, interactively:  /qcheck   (or /qship evals/fixtures/001-add-list-endpoint.md)
```

Run the *single skill* you changed (e.g. `/qcheck`, `/qbug`, `/qplan`) rather
than the whole pipeline — it's faster and isolates your change. Watch where the
agent struggles, ignores a section, or takes an unexpected path; that's your
signal (this is exactly how Anthropic recommends iterating on skills).

## 4. Behavioral eval (optional, for pipeline-level changes)

If you changed the pipeline orchestration (`qship`, `qshipmaster`, a phase gate
or hook), run the golden-set eval and compare scores to the baseline:

```bash
QSHIP_EVAL_EXEC=1 bash scripts/eval.sh --run --repo /path/to/sandbox
# scores land in evals/results/*.json — compare against the previous run
```

See [`../evals/README.md`](../evals/README.md) for the rubric and the judge.

## Notes

- `scripts/lint-forbidden.sh` is **maintainer-only** (it needs the private
  deny-list at `~/.qship-maintainer/`). As a contributor you don't run it;
  `check-no-local-leak.sh` is your equivalent self-check.
- Don't commit `config.json`, `answers/*`, or `evals/results/*` — they're
  gitignored and the pre-commit hook (`git config core.hooksPath scripts/githooks`)
  blocks the first two.
