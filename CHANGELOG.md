# Changelog

All notable changes to qship are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project is pre-1.x
community software and only the latest `main` is supported.

## [1.0.1] — 2026-06-05

### Fixed
- **`codex_integration_enabled: false` is now respected.** `load_json_config`
  flattened scalar leaves with `getpath($p) // ""`, but jq's `//` treats `false`
  as empty — so a `false` flag exported as `""` and fell back to the
  `command -v codex` default, making it impossible to disable Codex linking from
  config. Booleans are now preserved (`null → ""`, `false → "false"`) so the
  `true/false → y/n` mapping works.
- **Codex linking no longer touches the real `~/.codex` from an isolated install,
  and never clobbers your own symlinks.** The step wrote to a hardcoded
  `$HOME/.codex` (ignoring `CLAUDE_CONFIG_DIR`) and `ln -sfn`'d over any existing
  link with no backup. It now honours `CODEX_HOME` for isolation and backs up any
  pre-existing non-qship entry to `<link>.bak.<epoch>` before linking.
- **`SKILLS_ROOT` defaults to `$CLAUDE_DIR/skills`** (was a hardcoded
  `$HOME/.claude/skills`), so setting `CLAUDE_CONFIG_DIR` alone now fully isolates
  an install — skills, settings, and agents all land together — matching the
  documented intent and `setup.sh --check`. No-op for a normal install.

## [1.0.0] — 2026-05-31

First public release — the open-source, scrubbed distribution of a private
Claude Code + Codex CLI skill catalogue.

### The pipeline
- **Lean 21-skill pipeline.** qship ships only the 21 skills the
  `qship`/`qshipmaster` pipeline actually invokes (verified by exhaustive
  transitive-closure analysis of every `/qNAME` and `Skill:` edge). They install
  **unconditionally** — no skill-selection toggles — so the pipeline can never
  break from a missing transitively-required skill (e.g. core `qe2etest`
  hard-delegates to `qspinuplocal` and `qmanualt`). `codex_integration` is the
  only install flag.
- **Three-layer enforcement** — skill prose → blocking Bash hooks (no PR until
  E2E evidence is on disk) → an outer persistence loop that re-runs until a
  completeness check passes. State lives on disk, surviving compaction.

### Install & configuration
- **Bootstrapper model** — `/qship:configure` (or `bash setup.sh`) renders the
  21-skill pipeline into `~/.claude/skills/` from your answers; rendered skills
  and your config live outside the repo.
- **Flexible `repos[]` config** — single repo, 2-repo split, or N-service
  monorepo; no hardcoded slots. Per-repo flags (`has_migrations`, `runs_locally`,
  `is_primary`, `schema`, `port`) scope the repo-aware skills.
- **Issue-tracker abstraction** — choose `jira` or `none` at onboarding. `jira`
  uses your Atlassian MCP; `none` takes a pasted ticket / local file and skips
  all tracker calls. Single source of truth in
  `templates/skills/qship/references/tracker-contract.md`; `linear`/`github`
  reserved for future adapters.
- **Tenancy-agnostic** — multi-tenant guidance in the skills is written
  conditionally, so single-tenant codebases get no false "missing tenant
  isolation" findings.
- **`bash setup.sh --check`** — non-destructive health check (tooling, rendered
  skills, unfilled placeholders, `repos.json`, required companion plugins).
- **Self-explanatory skill descriptions** — every skill's `description` states
  what it does and when to use it (e.g. `qauthtrailingslash` now reads "Audit API
  routes for the trailing-slash / 307-redirect auth bug…"), so a contributor
  understands each command from its listing without opening the file. Command
  names are unchanged.

### Quality & contributor tooling
- **Behavioral eval harness** (`evals/` + `scripts/eval.sh`) — golden-set fixture
  tickets scored by an LLM-as-judge against a rubric; CI validates the scaffold
  (`--check`), full runs are opt-in. Plus `docs/TESTING-SKILLS.md` and a
  `docs/good-first-issues.md` starter list.
- **Contributor safety net** — `scripts/check-no-local-leak.sh` (your own config
  as the deny-list), a pre-commit hook (`git config core.hooksPath
  scripts/githooks`), and CI backstops (no tracked `config.json`/`answers/*`,
  gitleaks).
- OSS hygiene: `SECURITY.md`, `CODE_OF_CONDUCT.md`, PR + issue templates,
  `CODEOWNERS`, and `scripts/setup-repo.sh` (one-shot repo ruleset/merge/security
  config).

### Security
- Multiple audit passes + gitleaks + an AI security review; all real
  customer/business identifiers, internal hostnames, real ticket/PO/UUID and
  DB-endpoint values, and the original internal brand names scrubbed. Published
  git history is a single leak-free commit. Maintainer deny-list lint covers 114
  patterns.
- Hardened installer: JSON-only config, dynamic `export` guarded against env-var
  injection, `skills_root` validated before `rm -rf`.
- Documented the autonomy surface (`--dangerously-skip-permissions`) in the
  README.
