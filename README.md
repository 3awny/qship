# qship

**A ticket → production-PR pipeline for Claude Code & Codex CLI — that actually finishes the job.**

qship turns an issue into a shipped pull request: it plans, implements (TDD), reviews (multi-agent fan-out + bug hunt + validation), tests live end-to-end with evidence, and delivers the PR — and it's enforced by Bash hooks so an agent **can't** quietly skip a step, hallucinate "I'm done", or lose the plan to context compaction. One configurator installs the lean **21-skill pipeline** — exactly what qship runs, nothing more. Adapts to any codebase.

> **🚧 Work in progress — contributions very welcome.** qship is freshly open-sourced and still rough in places; it's verified-installable but not yet battle-tested across many setups. If you hit a snag, have an idea, or want to add a tracker/stack, please [open an issue or PR](CONTRIBUTING.md) — let's improve it together. Start with [`docs/good-first-issues.md`](docs/good-first-issues.md).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/3awny/qship/actions/workflows/ci.yml/badge.svg)](https://github.com/3awny/qship/actions/workflows/ci.yml)
![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757)
![Codex CLI compatible](https://img.shields.io/badge/Codex%20CLI-compatible-111111)
![Agent Skills standard](https://img.shields.io/badge/Agent%20Skills-standard-5b8def)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> Open-source distribution of a private skill catalogue. Real customer names, internal hostnames, credentials, and provider product names are scrubbed; the published history is a single, leak-free commit. See [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md) to wire it to your stack.

---

## Contents

- [Why qship](#why-qship)
- [The pipeline at a glance](#the-pipeline-at-a-glance)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Configure it for your codebase](#configure-it-for-your-codebase)
- [Quickstart](#quickstart)
- [What gets installed](#what-gets-installed)
- [Codex CLI integration](#codex-cli-integration)
- [Companion plugins (required)](#companion-plugins-required)
- [Security & autonomy](#security--autonomy)
- [Docs](#docs)
- [Contributing](#contributing)
- [Contact](#contact)
- [License](#license)

---

## Why qship

Plain agent runs fail in predictable ways on real, multi-step work:

- **The plan rolls out of context.** By step 8 of a 15-step task, the original spec is gone — so steps get dropped.
- **"I'm done" before it's done.** The agent reports success with the E2E test unrun and acceptance criteria unmet.
- **Soft rules get skipped under pressure.** "Skipped the TRD's edge case for time" — silently.

qship answers each with a **three-layer enforcement model**: the skill prose (soft rules) → blocking **Bash hooks** that refuse a tool call until the required artifact exists (e.g. no PR until E2E evidence is on disk) → an outer **persistence loop** that re-runs until a completeness check passes. State lives on disk, so the pipeline survives compaction, dropped sessions, and over-eager completion claims. (Full model in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).)

It runs on **Claude Code** by default and optionally delegates the implement and/or review steps to **Codex CLI** — different model families catch different defects.

## The pipeline at a glance

```text
Phase 1  Build      Jira/ticket fetch → repo detect → branch → plan → plan-review → TDD implement → directory/clean checks
Phase 1.5 Mirror    line-by-line spec-vs-code gap fix
Phase 2  Review     simplify → code-review fan-out (3–5 agents) → bug hunt → validation → fix → verification gate → quick E2E → memory capture
Phase 3  Accept     full E2E with captured evidence (screenshots / curl / DB)
Phase 4  Deliver    final test pass → open PR → watch CI → auto-fix CI → final review → completeness assertion
```

Every phase boundary is a hook gate: if a state file is missing or stale, the tool call is blocked. For epics, `/qshipmaster` plans dependency-ordered waves and ships one consolidated PR per repo.

## Prerequisites

- **Platform: macOS or Linux.** The installer and hooks are portable POSIX
  `bash` (no macOS- or GNU-only constructs); Linux is exercised on every CI run.
  **Windows: use [WSL2](https://learn.microsoft.com/windows/wsl/install)** and
  follow the Linux steps inside it — native PowerShell/cmd is not supported
  (qship is bash + `envsubst`).
- **Claude Code** (required). **Codex CLI** optional, for `provider=codex` / `reviewer=codex`.
- **`jq`** + **`envsubst`** (gettext) on `PATH` — the installer renders templates with them:
  - macOS: `brew install jq gettext`
  - Debian/Ubuntu (incl. WSL): `sudo apt-get install -y jq gettext`
  - Fedora/RHEL: `sudo dnf install -y jq gettext`
  - Arch: `sudo pacman -S jq gettext`
- **`git`**, plus **`gh`** for Phase-4 PR creation.
- **Five companion plugins** — qship's review / bug-hunt / simplify steps delegate to them (see [Companion plugins](#companion-plugins-required)). `bash setup.sh --check` tells you which are missing.
- **An issue tracker — your choice at onboarding (`jira` or `none`):**
  - **`jira`** → connect an **Atlassian MCP** in Claude Code. It holds your Jira/Confluence credentials; **qship stores no token**, only an optional non-secret cloud id. Used by the ticket-driven skills (`/qship`, `/qshipmaster`) to fetch + transition tickets.
  - **`none`** → no tracker MCP. Paste a ticket/spec or point at a local markdown file; `/qship` uses it directly. The review skills (`/qcheck`, `/qbug`, `/qe2etest`, …) never needed a tracker.
  - `linear` / `github` are reserved for future adapters (accepted, currently treated as `none`).

## Install

qship is a **bootstrapper**: installing the plugin gives you one skill, `/qship:configure`, which asks a short questionnaire + a per-repo loop and renders the 21-skill pipeline into `~/.claude/skills/`.

**Option A — Plugin marketplace** (recommended for Claude Code):

```text
/plugin marketplace add 3awny/qship
/plugin install qship
```

A `SessionStart` hook then nudges you to run, inside Claude Code:

```text
/qship:configure
```

**Option B — Setup script** (Claude Code *or* Codex CLI):

```bash
git clone https://github.com/3awny/qship.git
cd qship
bash setup.sh
```

Both render skills into `~/.claude/skills/<name>/` (and symlink into `~/.codex/skills/` if `codex` is on `PATH`), merge hooks into `~/.claude/settings.json` (timestamped backup first), write `repos.json`, and print a quickstart. **Your real values never enter the repo** — rendered skills and your `config.json` / `answers/*` live outside it (and are gitignored).

**Verify any time:**

```bash
bash setup.sh --check     # tooling, rendered skills, repos.json, required plugins → exit 0 if healthy
```

### Windows (WSL2)

qship is POSIX `bash` — run it inside **[WSL2](https://learn.microsoft.com/windows/wsl/install)** (a real Linux environment on Windows), **not** native PowerShell/cmd. `setup.sh` detects native Windows shells and points you here.

```powershell
wsl --install            # admin PowerShell; reboot if prompted
```

Then open **Ubuntu** from the Start menu and run the Linux steps:

```bash
sudo apt-get update && sudo apt-get install -y jq gettext
git clone https://github.com/3awny/qship.git && cd qship && bash setup.sh
```

WSL2 is also where Claude Code's OS-level sandbox works — recommended for qship's unattended mode.

## Configure it for your codebase

**Repos — any shape.** No hardcoded `core`/`app` slots; declare 1 repo or 100 as a `repos[]` array. Per-repo flags opt a repo into the skills that need it:

```json
{ "repos": [
  { "name": "my-app", "kind": "monolith", "schema": "public",
    "has_migrations": true, "runs_locally": true, "is_primary": true, "port": 8000 }
] }
```

- `is_primary` → resolves `{{PRIMARY_REPO_NAME}}` everywhere · `has_migrations` → migration skills · `runs_locally` → local-stack skills.

**Issue tracker** is a one-line config (`tracker.tracker_type`) chosen at onboarding — see [Prerequisites](#prerequisites). Adding a new tracker (Linear, GitHub Issues) is a documented ~4-file change, not a per-skill edit — see [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md).

**Re-run anytime** to change a value: `/qship:configure`, or `bash setup.sh --config answers/last-run.json`.

## Quickstart

```text
/qship PROJ-42                          # default: Claude implements + Claude reviews
/qship PROJ-42 provider=codex           # Codex implements; Claude reviews + ships
/qship PROJ-42 reviewer=codex           # Claude implements; Codex (gpt-5.5) reviews the bug-hunt phase
/qshipmaster PROJ-555 reviewer=codex    # epic mode: dependency-ordered waves, one PR per repo
```

Many skills work standalone, too — e.g. `/qcheck` (code review), `/qbug` (root-cause bug hunt), `/qe2etest` (live smoke test), `/qplan` (plan review).

## What gets installed

qship installs the **full 21-skill pipeline** every time — there are no skill-selection toggles. Every skill is reachable from the `qship`/`qshipmaster` pipeline (directly or transitively), so installing fewer would break it at runtime. The catalogue is intentionally lean: only what the pipeline actually runs ships in the repo.

- **Pipeline + gates:** `qship`, `qshipmaster`, `qshipcheck`, `qshipphasecheck`
- **Build:** `qplan`, `qdirectory`, `qclean`, `qreuse`
- **Review:** `qcheck`, `qcheckt`, `qcheckf`, `qcomponent`, `qbug`, `qbcheck`
- **Accept + memory:** `qe2etest`, `qmanualt`, `qspinuplocal`, `qlocalclonedb`, `qmemory`
- **Stack checks (fire only when your diff needs them):** `qmigrationdevcheck` (Alembic migrations), `qauthtrailingslash` (FastAPI routes)

Plus the `qship-worker` agent and the enforcement hooks. The only install flag is whether to also symlink the skills into `~/.codex/skills/` for Codex CLI.

## Codex CLI integration

If `codex` is on `PATH` at install, skills are symlinked into `~/.codex/skills/`. `/qship` and `/qshipmaster` accept `provider=codex` (Codex implements) and `reviewer=codex` (Codex runs the Phase-2 bug hunt). See [`docs/CODEX.md`](docs/CODEX.md).

## Companion plugins (required)

qship delegates several steps to official Anthropic plugins. Install them once — `setup.sh --check` flags any that are missing (the #1 cause of a failed first run):

```text
/plugin marketplace add anthropics/claude-plugins-official
/plugin install superpowers feature-dev code-review code-simplifier pr-review-toolkit
```

`superpowers` (plan / TDD / code-review), `feature-dev` (code-review), `code-review` (final PR review), `code-simplifier` (simplify pass), `pr-review-toolkit` (verification + sibling reviewers).

## Security & autonomy

qship's unattended loop spawns headless `claude --print --dangerously-skip-permissions` — sessions that run shell commands and edit files **without per-tool prompts**. That's how it ships unattended, but it means:

- **Sandbox it.** Run qship in a container or VM, not on your primary machine — Anthropic's own guidance for `--dangerously-skip-permissions` is *"run this in a container, not your actual machine."* The flag is blocked under `root`/`sudo` by design; don't work around that.
- **Treat every input as untrusted.** Prompt injection via a hostile ticket, TRD, PR, or fetched URL is the leading agent risk — a malicious ticket the agent reads becomes instructions it may act on. Run it only in a trusted working tree (ideally an isolated git worktree, which the pipeline creates per ticket), and review the diff before merging.
- Credentials stay in gitignored `.env` files — skills reference env-var *names* only; qship stores no secrets.
- Prefer running individual review skills interactively if unattended execution isn't acceptable in your environment.

Full policy and how to report a leak/vulnerability privately: [`SECURITY.md`](SECURITY.md).

## Docs

| Doc | What's in it |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | the three-layer enforcement model + phase diagrams |
| [`docs/CUSTOMIZING.md`](docs/CUSTOMIZING.md) | adapting to your repos, tracker, DB/auth providers |
| [`docs/CODEX.md`](docs/CODEX.md) | `provider=codex` / `reviewer=codex` mechanics |
| [`docs/HOOKS.md`](docs/HOOKS.md) | what each hook blocks and how to debug a block |
| [`docs/TESTING-SKILLS.md`](docs/TESTING-SKILLS.md) · [`evals/`](evals/) | how to smoke-test a skill change + the behavioral eval harness (golden-set + LLM-as-judge) |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`CHANGELOG.md`](CHANGELOG.md) · [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) | contribute, release notes, conduct |

## Contributing

PRs welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide and [`docs/TESTING-SKILLS.md`](docs/TESTING-SKILLS.md) for how to test a skill change. In short: edit `templates/skills/<name>/`, then run `bash scripts/validate-placeholders.sh` + `bash scripts/check-no-local-leak.sh` + `bash scripts/eval.sh --check` (and install the pre-commit hook: `git config core.hooksPath scripts/githooks`). CI enforces the same checks plus a gitleaks scan. The `templates/` are hand-maintained; a contributor self-check makes sure none of *your* onboarded values leak into a PR. New here? Browse [`docs/good-first-issues.md`](docs/good-first-issues.md).

## Contact

Maintained by **Ahmed Awny** — [ahmedawny.one@gmail.com](mailto:ahmedawny.one@gmail.com). For bugs and feature requests, open an issue; to report a security leak or vulnerability privately, see [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) — © qship contributors.
