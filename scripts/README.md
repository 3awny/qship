# scripts/ — lint + validate tooling

## Files

| File | Purpose | Audience |
|---|---|---|
| `lint-forbidden.sh` | Greps the repo for any of the maintainer's forbidden patterns; fails if any match. | **Maintainer only** (needs the private deny-list below). |
| `validate-placeholders.sh` | Verifies every `{{PLACEHOLDER}}` used in `templates/` is defined in `config.example.json`. | CI. |
| `check-no-local-leak.sh` | Fails if your own onboarded `answers/` values appear in a tracked file. | Contributor + CI. |
| `setup-repo.sh` | One-time GitHub repo configuration (merge strategy, ruleset, security features) via `gh`. | Maintainer. |

## Where the lint deny-list lives (NOT in this repo)

`lint-forbidden.sh` reads its pattern file from `$QSHIP_MAINTAINER_DIR` (default `~/.qship-maintainer/`):

```
~/.qship-maintainer/
└── forbidden-strings.txt   # one regex pattern per line
```

**This file is the cleartext deny-list (real names, real provider names, real internal
paths) and MUST NOT be committed to this public repo** — shipping it would defeat the
scrubbing exercise, since anyone reading it could reverse-link every placeholder back to
its original value.

If you're forking this repo to maintain your own scrubbed catalogue, create the directory
yourself and add `forbidden-strings.txt` with one regex per line.
