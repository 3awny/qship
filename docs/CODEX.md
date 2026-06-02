# Using qship with Codex CLI

`qship` and `qshipmaster` accept two engine flags that route work between Claude and OpenAI Codex:

- `provider=claude` (default) | `provider=codex` — chooses the Step 7 implementer
- `reviewer=claude` (default) | `reviewer=codex` — chooses the Phase 1/2 reviewer

The four combinations:

```text
/qship PROJ-42                                  # Claude implements + Claude reviews
/qship PROJ-42 provider=codex                   # Codex implements + Claude reviews
/qship PROJ-42 reviewer=codex                   # Claude implements + Codex (gpt-5.5 high) reviews
/qship PROJ-42 provider=codex reviewer=codex    # all Codex (discouraged — same-family review)
```

The diversified `provider=claude reviewer=codex` is the recommended non-default combination: Opus implements with the strongest in-skill memory loaded, then gpt-5.5 at high reasoning effort hunts bugs from a different family's perspective.

## Prerequisites

- Codex CLI installed and authenticated:
  ```bash
  codex --version    # expect "codex x.y.z"
  codex auth status
  ```
- `gpt-5.5` available in your Codex model picker:
  ```bash
  codex exec --model gpt-5.5 -c model_reasoning_effort=high - <<< "echo ok"
  ```

If either fails, qship refuses to start under `provider=codex` / `reviewer=codex` and surfaces the install instructions.

## How Codex sees the same skill catalog as Claude

This installer symlinks every rendered skill under `~/.claude/skills/` into `~/.codex/skills/` if you set `CODEX_INTEGRATION_ENABLED=y` during setup. Codex's [Agent Skills](https://developers.openai.com/codex/skills) scan `~/.codex/skills/<name>/SKILL.md` with the same YAML frontmatter format Claude uses, so `qcheckt`, `qclean`, `qbug`, `qbcheck`, etc. are reachable from `codex exec` via `/skills <name>` or `$<skill-name>` mentions.

To refresh symlinks after adding or removing a skill:

```bash
bash setup.sh --config answers/last-run.json
```

## What `provider=codex` swaps

Only Step 7's TDD inner loop is delegated to `codex exec --model gpt-5.5 -c model_reasoning_effort=high` per task. See `~/.claude/skills/qship/step7-codex-override.md` after install for the full per-task prompt template, JSONL capture, and the fallback contract (2 failed Codex attempts → Claude takes the task).

Carve-outs — even under `provider=codex` these stay in Claude:
- Migration files (alembic / equivalent)
- Cross-repo enum or URL contract changes
- RLS / tenant scoping / auth middleware

## What `reviewer=codex` swaps

Steps 6 (Plan Review), 7.5 (Simplify), 8.1-8.4 (Code review fan-out), 9 (Bug Hunt slots), 10 (qbcheck) all delegate to `codex exec`. See `~/.claude/skills/qship/reviewer-codex-override.md` for per-step prompt templates and the JSONL capture protocol.

Always-Claude steps even under `reviewer=codex`:
- Step 8.5.1 (qmigrationdevcheck) — depends on Claude's MCP tool integrations
- Step 8.6.5 (qauthtrailingslash) — same
- Step 11 (Fix Issues) — Claude's skill stack matters for applying findings
- Step 11.5 (Verification Gate)
- Step 11.6 (`/qe2etest`), 11.7 (`/qmemory`)
- The qshipmaster wave-gate + epic-end Phase 2 review

## Cost / quality expectations (anecdotal)

On boilerplate-heavy tickets (CRUD endpoints, repository methods, test scaffolding):
- `provider=codex` cuts implementation wall-time and API spend ~3-5× vs Claude TDD
- `reviewer=codex` adds ~30% to review wall-time but catches a different set of bugs (off-by-one, silent failure, edge cases) than Claude's reviewer skills

On architectural / cross-repo / migration-heavy tickets:
- `provider=codex` is a net loss — gpt-5.5 doesn't load your project-specific memory rules
- `reviewer=codex` still helpful for the diversity-of-model signal

Measure on your own tickets before generalising.
