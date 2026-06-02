# Contributing to qship

Thanks for taking the time. This is a working open-source mirror of a private skill catalogue — the docs below explain what's editable, what's not, and the simplest contribution flow for each scenario.

## TL;DR — common tasks

| Want to… | Edit | Test | PR target |
|---|---|---|---|
| Fix a typo in a skill body | `templates/skills/<name>/<file>` | run `bash scripts/validate-placeholders.sh` | `main` |
| Improve a skill's prose / add a checklist item | `templates/skills/<name>/<file>` | run `bash setup.sh --dry-run` | `main` |
| Add a new skill | new dir under `templates/skills/<name>/` with `SKILL.md` | rebuild + lint + validate | `main` |
| Add a new placeholder | `templates/skills/<file>` (use it) + `config.example.json` (declare it) + `setup.sh` (ask for it) + `config.schema.json` (document it) | `bash scripts/validate-placeholders.sh` should pass | `main` |
| Fix a bug in `setup.sh` | `setup.sh` | run `bash -n setup.sh` for syntax + try `bash setup.sh --dry-run` | `main` |
| Tighten `lint-forbidden.sh` rules | `scripts/lint-forbidden.sh` | `bash scripts/lint-forbidden.sh` on the current repo | `main` |
| **Add a scrub rule (substitution map)** | **NOT POSSIBLE FROM A PR — see below** | — | — |

## Repository structure

```
qship/
├── README.md                  user-facing install + quickstart
├── LICENSE                    MIT
├── CONTRIBUTING.md            this file
│
├── plugin.json                Claude Code plugin manifest (minimal schema-compliant)
├── .marketplace.json          plugin-marketplace manifest
│
├── config.example.json        ← CANONICAL example config. Copy to config.json, edit.
├── config.schema.json         JSON schema documenting every field
│
├── setup.sh                   interactive installer (terminal)
├── uninstall.sh               reverse of setup.sh
│
├── hooks/                     plugin-root hooks (SessionStart first-run prompt)
│   ├── hooks.json
│   └── first-run-check.sh
│
├── skills/                    plugin-root skills (the bootstrapper itself)
│   └── configure/             /qship:configure wizard
│       └── SKILL.md
│
├── templates/                 ← THE BULK OF THE REPO — every skill ends up here
│   ├── agents/
│   │   └── qship-worker.md    (plain .md — no .tpl extension!)
│   ├── hooks-settings/
│   │   └── qship-hooks.json   (snippet jq-merged into ~/.claude/settings.json)
│   └── skills/
│       ├── qship/
│       │   ├── SKILL.md
│       │   ├── pipeline-steps.md
│       │   ├── parallel-execution.md
│       │   ├── step7-codex-override.md
│       │   ├── reviewer-codex-override.md
│       │   ├── references/autonomy-contract.md
│       │   └── hooks/*.sh
│       ├── qshipmaster/
│       └── ... (60+ more)
│
├── scripts/                   build / lint / validate tooling
│   ├── README.md              explains the lint tooling + the private deny-list
│   ├── lint-forbidden.sh      MAINTAINER — refuses files containing real customer data
│   └── validate-placeholders.sh  CI — every {{PLACEHOLDER}} in templates is defined in config.example.json
│
├── deps/
│   └── plugin-marketplaces.txt    external plugin deps (printed by setup.sh)
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── CUSTOMIZING.md
│   ├── CODEX.md
│   └── HOOKS.md
│
└── answers/                   (gitignored — your install's answers cache)
```

## Your local install can't leak into your PR

This repo is designed so that **onboarding (running `setup.sh` / `/qship:configure` with your real company, repos, home path, DB user, etc.) is fully detached from the publishable source.** Three guarantees:

1. **Rendered skills land *outside* the repo.** `setup.sh` writes the filled-in skills to `~/.claude/skills/`, never back into `templates/`. The artifacts that contain your real values never sit in the repo tree, so they can't be `git add`ed.
2. **Your answers are gitignored.** `config.json` and `answers/last-run.*` (which hold your real values) are in `.gitignore` and are never tracked. A normal `git add -A` skips them.
3. **You edit only generic placeholders.** `templates/` contains `{{PLACEHOLDER}}` tokens, not values.

The one thing the above *doesn't* catch automatically is fat-fingering a real value (your repo name, company slug, home path) directly into a template body instead of the placeholder. So:

- **Install the pre-commit hook (one command, no dependencies):**
  ```bash
  git config core.hooksPath scripts/githooks
  ```
  It blocks staging your local config and runs the self-check below on every commit.
- **Or run the self-check manually anytime:**
  ```bash
  bash scripts/check-no-local-leak.sh
  ```
  It reads *your own* `answers/last-run.json`, builds a deny-list of the values you changed from the generic example, and greps every tracked file for them — failing if any of your onboarded values appears somewhere publishable. It needs no maintainer files and no-ops if you never onboarded.

CI enforces the server-side half too (it rejects any committed `config.json`/`answers/*` and runs gitleaks for credentials), so even without the hook a leak can't merge.

> **Heads-up on `templates/`:** the maintainer keeps `templates/` as the canonical source. Your PR edits to `templates/` are reviewed and may be adapted by the maintainer rather than merged verbatim. Small prose/checklist fixes are frictionless; large structural changes are best discussed in an issue first.

## The placeholder system

Every templated file in `templates/` (skill bodies, hook scripts, the agent definition) can contain `{{PLACEHOLDER}}` tokens. These get filled in at install time by `envsubst` reading from the values in `config.json` (or `answers/last-run.json` on re-runs).

Example: a skill body might say

```markdown
Run `pytest` from {{CODEBASE_ROOT}}/{{PRIMARY_REPO_NAME}}/ before opening a PR.
```

At install time this renders to (depending on `config.json` values):

```markdown
Run `pytest` from /home/you/work/your-monorepo/core/ before opening a PR.
```

**To add a new placeholder, you must touch four files:**

1. **Use it** in a templated file: `templates/skills/<name>/<file>`
2. **Declare it** in `config.example.json` (under the appropriate nested group)
3. **Add a prompt for it** in `setup.sh` (so users get asked during the questionnaire)
4. **Document it** in `config.schema.json` (description + type)

The `scripts/validate-placeholders.sh` script catches the most common omission (#1 without #2) — run it before opening your PR. Or `bash setup.sh --dry-run` to confirm the install path doesn't fail.

## Adding an issue tracker (Linear, GitHub Issues, …)

qship ships with `jira` and `none`. Adding another tracker is **additive** — it does **not** mean editing every ticket-driven skill, because they all hold a one-line pointer to a single source of truth. You touch ~4 files:

1. **`config.schema.json`** — add the value to the `tracker.tracker_type` enum.
2. **`setup.sh`** (the tracker `case`) + **`skills/configure/SKILL.md`** (Round 1 question) — accept the value instead of downgrading it to `none`.
3. **`templates/skills/qship/references/tracker-contract.md`** — this is the single source of truth. Replace the provider's *reserved* stub with a real section mapping the five operations — **FETCH / CHILDREN / CREATE / TRANSITION / READ-TRD** — to that provider's MCP tool names. (Linear and GitHub both have MCP servers; an "epic" maps to a Linear project/initiative or a GitHub tracking issue/milestone.)
4. **`templates/skills/qship/hooks/qship-persist.sh`** — add one arm to each of the two `case "{{TRACKER_TYPE}}"` blocks (AC fetch + epic-children) for the unattended loop.

**That's the whole list.** The ticket-driven skills (`qship`, `qshipmaster`) need **no changes** — they render `tracker = <type>` and point at the contract file. Everything downstream (planning, review, tests, PR) operates on the resolved spec text + git, never on the tracker. Test with `bash setup.sh --config <a config with your tracker_type>` and confirm the rendered skills + persist hook carry your new arm.

## What you CAN'T contribute via PR

The **anonymisation / scrub deny-list** is intentionally maintainer-only. It lives OUTSIDE this public repo at `~/.qship-maintainer/`:

- `forbidden-strings.txt` — lint patterns that block real customer data from leaking

These contain the cleartext deanonymisation key (real customer names, real provider names, real internal paths, real personal info). Shipping them publicly would defeat the entire scrubbing exercise — anyone reading them could reverse-link every placeholder back to the original value.

If you've forked this repo to maintain your own scrubbed skill catalogue, create your own `~/.qship-maintainer/` directory locally for the lint deny-list (`lint-forbidden.sh` reads it). **Don't commit it.**

If you've found a leak in the current public templates (real customer data slipping through), please report it via a private issue (or email the maintainer) so the scrub map can be tightened without publishing the new pattern.

## Local development cycle

```bash
git clone <your-fork> qship
cd qship

# Editing a skill body:
$EDITOR templates/skills/qship/SKILL.md     # plain .md, no .tpl extension

# One-time: install the contributor pre-commit hook (blocks local-config leaks)
git config core.hooksPath scripts/githooks

# Validate before commit:
bash scripts/validate-placeholders.sh        # CI gate: placeholders declared
bash scripts/check-no-local-leak.sh          # CI/hook gate: none of YOUR values leaked
bash scripts/eval.sh --check                 # CI gate: eval fixtures + rubric well-formed
bash setup.sh --dry-run                      # confirm install path doesn't fail

# Test the install end-to-end against a throwaway location:
TEMP_HOME=$(mktemp -d)
HOME="$TEMP_HOME" SKILLS_ROOT="$TEMP_HOME/.claude/skills" bash setup.sh --config config.example.json
ls "$TEMP_HOME/.claude/skills/"             # confirm skills landed

# Commit + PR
git add -A && git commit -m "qcheck: add new bullet on cross-repo grep"
git push origin my-branch
```

## CI gates (run locally before pushing)

1. **`bash scripts/validate-placeholders.sh`** — every `{{TOKEN}}` used in a template is declared in `config.example.json`.
2. **`bash scripts/check-no-local-leak.sh`** — none of *your* onboarded values appear in a tracked file (no-ops if you haven't onboarded).
3. **`bash scripts/eval.sh --check`** — the behavioral-eval fixtures + rubric are well-formed (see [`docs/TESTING-SKILLS.md`](docs/TESTING-SKILLS.md) for the full behavioral eval).
4. **`bash setup.sh --dry-run`** — the install path doesn't error out on the current repo state.
5. **`bash -n setup.sh && bash -n uninstall.sh`** — shell syntax check.

CI additionally enforces, server-side: **no `config.json`/`answers/*` is ever tracked**, and **gitleaks** scans the full history for credentials. These two run on every PR regardless of whether you installed the pre-commit hook.

6. **(Maintainer-only) `bash scripts/lint-forbidden.sh`** — runs against `~/.qship-maintainer/forbidden-strings.txt`; passes if no real customer data leaked into rendered templates.

## Maintainer: repo configuration

After the repo is pushed to github.com, the maintainer applies the open-source
repo settings (squash-only merges, auto-delete branches, a branch ruleset that
requires CI + blocks force-push/deletion, secret scanning + push protection,
Dependabot) in one shot:

```bash
gh auth login --hostname github.com   # if gh is on a different host
bash scripts/setup-repo.sh            # or: bash scripts/setup-repo.sh OWNER/REPO
DRY_RUN=1 bash scripts/setup-repo.sh  # preview the gh calls without applying
```

It's idempotent and refuses to run if `gh` is authenticated to a non-github.com
host. `.github/CODEOWNERS` auto-requests the maintainer on every PR.

## Conventions

- **Markdown body**: plain GitHub-flavoured Markdown. No HTML. Skill names invoked as `/qship`, `/qcheck`, etc. (with leading slash).
- **Placeholders**: `{{UPPER_SNAKE_CASE}}` always. Match a key in `config.example.json`.
- **Shell scripts**: bash, POSIX-portable when feasible. Use `set -euo pipefail` in any new scripts. Use `[[:<:]]` / `[[:>:]]` for word boundaries (BSD sed compat) instead of `\b`.
- **JSON**: 2-space indent, trailing newline, no trailing commas.
- **Commit messages**: imperative present tense. First line ≤72 chars. Body wrapped at ~80 chars.

## Reporting bugs / requesting features

GitHub Issues on this repo. For sensitive reports (real customer data leak in a published template), open a private security advisory or email the maintainer directly — don't post the leak publicly.

## Code of Conduct

Be kind. Assume good faith. Reviewers prioritise getting your fix merged over style nits — but please run the CI gates locally so reviewers don't have to ping you for "rebase + fix lint" five times.

Thanks for contributing.
