# Autonomy & Read-Before-Execute Contract

**Single source of truth for qship's persistence and step-discipline rules.** SKILL.md, pipeline-steps.md, parallel-execution.md, and every spawned sub-agent prompt link here instead of restating these rules.

## Why this file exists separately

A skill is a prompt. Prompts are suggestions an LLM can hallucinate compliance with. qship backs the soft rules below with hard enforcement: `PreToolUse`, `Stop`, and `SubagentStop` hooks installed in `~/.claude/settings.json`. The hooks (`require-phase3-evidence.sh`, `require-pipeline-complete.sh`, `qship-persist.sh`) are the actual enforcement layer; this file documents the intent so the orchestrator and sub-agents reason consistently.

If a hook is missing or unregistered, treat every rule below as advisory. Verify with:

```bash
jq '.hooks | keys' ~/.claude/settings.json
# expect: PreToolUse, Stop, SubagentStop
```

## The contract

You are a fully autonomous agent inside `qship-persist.sh`. There is no human reading your output. The persist wrapper IS the autonomy mechanism. You only stop when `/qshipcheck` returns PASSED.

### Persistence

The Anthropic prompt-engineering guide, Cursor 2.0, and the Devin self-critique pattern all converge on the same rule:

> Continue working until the task is completely resolved. Don't stop early because of token budget — context compaction is automatic; save state to the filesystem (`phase2-progress.md`, `phase3-evidence.md`, `trd-coverage.json`) so the next iteration resumes. Before reporting completion, critically examine your work: did every changed location get edited? Did every test get re-run? Did every acceptance criterion get exercised live?

Operational consequences for qship:

1. Never report completion until `/qshipcheck` returns PASSED. If it returns FAIL, re-run the missing steps and re-check. No iteration cap.
2. Never stop Phase 2 with the verification gate red. Return to the fix loop, re-verify. No cap.
3. Never stop Phase 3 with `qe2etest` coverage gaps (including the UI portion `/qe2etest` delegates to `/qmanualt`). Redispatch with specific gap targets. Loop until every AC row has a PASS with live evidence.
4. Never ask the user to choose between approaches. Pick the most-complete option and execute.
5. Never wrap up because context is tight. Compaction is automatic; save progress and continue.
6. When a sub-agent reports "skipped for time", "too complex", "stub", "TODO", "deferred", "follow-up": SendMessage telling it to finish; if it refuses, dispatch a fresh sub-agent at the gap. Loop.
7. Escalate to the user only for: credentials/VPN unreachable, OR same task failed 3 consecutive attempts with distinct root-cause fixes attempted.

### Read-before-execute

Before executing any pipeline step, read the FULL content of the relevant skill, command, or instruction file. Skills contain edge cases and gotchas only visible when read fully — skimming headers and guessing produces silent failures (e.g., subagents missing `qmanualt`'s DEV_MODE patches and getting auth-blocked).

This applies to:
- The skill being invoked (e.g., when a step says "invoke `/qe2etest`", read `~/.claude/skills/qe2etest/SKILL.md` in full — and `~/.claude/skills/qmanualt/SKILL.md` too, since qe2etest delegates UI flows to it)
- Referenced files within the same skill ("see [pipeline-steps.md]" means read it end-to-end, not skim to the section you think is relevant — steps have preconditions and cross-references)
- The pipeline table — every row is mandatory; "the code looks clean" is not grounds to skip bug hunting

### No-skip / no-substitute rule

No phase, step, or sub-step may be skipped or "simplified" with an alternative. When the spec says "dispatch 5 bug-hunter agents", you dispatch exactly 5. When it says "invoke the Skill tool", you invoke the Skill tool, not a manual approximation. When it says "run the full test suite", you run the full test suite, not a subset.

If `/qshipcheck` (Step 15) detects any skipped step, the whole pipeline is FAILED and re-runs from the first skip.

Past failures this rule prevents:
- Orchestrators skipping Phase 2 review steps because "the subagent already reviewed"
- Subagents skipping `qmanualt`'s DEV_MODE patches and getting blocked by auth
- Skills invoked without reading their content, leading to incorrect execution
- Steps marked DONE without dispatching the required agents/tools

### Local DB writes are pre-authorised

Any write to `{{LOCAL_DEV_DB_NAME}}` (`postgresql://{{LOCAL_DB_USER}}@localhost:5432/{{LOCAL_DEV_DB_NAME}}` or any env var pointing at that host/DB) is auto-approved for the duration of qship: INSERT, UPDATE, DELETE, TRUNCATE, DDL, test-data seeding via `qmanualt`. Never pause to ask permission for a local DB mutation — the DB is a disposable clone and is rebuilt with `python scripts/bootstrap_local_db.py --tenant "Example Tenant" --env-file .env.dev`.

Permission prompts remain required for: staging the Postgres provider (`*.example-postgres.com`), production DB, remote pushes, cloud services (the cloud blob store, shared the external auth provider tenants), and cross-tenant writes to the local app schema.

The project `.claude/settings.local.json` allowlist pre-authorises the bash patterns qship routinely runs (alembic, `run_all_migrations`, `{{STATE_ROOT}}/worktrees/*` scripts, worktree `cp` commands, `claude -p /qship*`). Prompts do not auto-approve anything — the JSON file does.

## Sub-agent dispatch contract

Every Task() / sub-agent prompt spawned by qship must include a one-line directive pointing here:

```
Read ~/.claude/skills/qship/references/autonomy-contract.md before starting. It is non-negotiable.
```

Do NOT paste this entire file into every sub-agent prompt — that wastes tokens proportional to (sub-agents × iterations). The pointer is sufficient; sub-agents have Read access.
