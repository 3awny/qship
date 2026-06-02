<!-- Thanks for contributing to qship! Keep PRs focused; see CONTRIBUTING.md. -->

## What & why

<!-- One or two sentences: what this changes and the motivation. -->

## Type of change

- [ ] Skill prose / checklist fix (`templates/skills/<name>/<file>`)
- [ ] New skill
- [ ] New `{{PLACEHOLDER}}` (also touched `config.example.json` + `setup.sh` + `config.schema.json`)
- [ ] New issue tracker (touched `tracker-contract.md` + enum + setup + persist-hook `case` — see CONTRIBUTING → "Adding an issue tracker")
- [ ] `setup.sh` / tooling
- [ ] Docs only

## Checklist (run locally — CI runs these too)

- [ ] `bash scripts/validate-placeholders.sh` — every `{{TOKEN}}` is declared
- [ ] `bash scripts/check-no-local-leak.sh` — none of **my** onboarded values (company, repo names, home path) leaked into a tracked file
- [ ] `bash setup.sh --dry-run` — install path doesn't error
- [ ] `bash -n` passes on any shell script I touched
- [ ] I did **not** commit `config.json` or `answers/*` (gitignored — the pre-commit hook blocks this; install it with `git config core.hooksPath scripts/githooks`)
- [ ] I did **not** hardcode a real value where a `{{PLACEHOLDER}}` belongs
- [ ] If I touched `templates/`, I understand it's hand-maintained (not regenerated) as of v1.0.0

## Notes for reviewers

<!-- Anything non-obvious, trade-offs, or follow-ups. -->
