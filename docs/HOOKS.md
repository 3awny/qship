# Hooks reference

qship registers 7 hooks in `~/.claude/settings.json`. Each is a Bash script that returns either nothing (allow the tool call) or `{"decision": "block", "reason": "..."}` (refuse it).

## Verifying they're wired

```bash
jq '.hooks | keys' ~/.claude/settings.json
# expect: ["PreToolUse", "Stop", "SubagentStop"]

jq '.hooks.PreToolUse[].hooks[].command' ~/.claude/settings.json | grep qship
```

## What each hook does

### `require-phase3-evidence.sh`
**Fires:** PreToolUse on Bash when the command contains `gh pr create`, `git push ... <TICKET>`, or `gh pr comment`.
**Blocks:** if `${STATE_ROOT}/<TICKET>/phase3-evidence.md` is missing, empty, or lacks both HTTP/curl output AND a "no network surface" rationale.
**Debug:** `bash ${SKILLS_ROOT}/qship/hooks/require-phase3-evidence.sh < /dev/null`

### `require-pre-pr-test-pass.sh`
**Fires:** PreToolUse on `gh pr create`.
**Blocks:** if `${STATE_ROOT}/<TICKET>/phase4-tests-passed.<repo>.flag` is missing for any affected repo (Step 12.0 didn't run a fresh-green test pass).

### `require-qe2etest-evidence.sh`
**Fires:** PreToolUse on Phase 3-adjacent commands.
**Blocks:** if Step 11.6's `/qe2etest` didn't produce its log file.

### `require-phase3-critic.sh`
**Fires:** PreToolUse before Phase 4.
**Blocks:** if the `qphase3critic` Sonnet pass didn't verify Phase 3 evidence.

### `require-pipeline-complete.sh`
**Fires:** Stop and SubagentStop (every attempted termination).
**Blocks:** while
- a `phase2-progress.md` row is still `PENDING`, OR
- `phase3-evidence.md` is empty / lacks HTTP evidence / lacks "no network surface" rationale, OR
- `trd-coverage.json` has any row with `passes: false`.
Has a `stop_hook_active` guard to prevent infinite loops. Stale worktrees (>4h untouched) are treated as abandoned and do NOT block — `rm -rf ${STATE_ROOT}/<TICKET>` to clear a stuck block.

### `require-epic-scope-coverage.sh`
**Fires:** PreToolUse for workers under `EPIC_MODE=true`.
**Blocks:** if the worker touches files outside its assigned ticket's scope (defined in `${STATE_ROOT}/epic-<EPIC>/tickets/<TICKET>/scope.json`).

### `block-pr-create-in-epic-mode.sh`
**Fires:** PreToolUse on `gh pr create` when `EPIC_MODE=true`.
**Blocks:** the worker from creating individual PRs — under epic mode, only the orchestrator creates one consolidated PR per repo.

## Disabling hooks (debug / opt-out)

To temporarily disable all qship hooks:

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.qship-off
jq 'del(.hooks)' ~/.claude/settings.json.qship-off > ~/.claude/settings.json
```

Restore with:

```bash
mv ~/.claude/settings.json.qship-off ~/.claude/settings.json
```

## Common block patterns + fixes

| Block message | Real cause | Fix |
|---|---|---|
| "Phase 3 evidence missing for `<TICKET>`" | qmanualt didn't write `phase3-evidence.md` | Re-run `/qmanualt <TICKET>` in the worktree |
| "phase4-tests-passed.flag missing for `<repo>`" | Step 12.0 was skipped | Run `cd <worktree>/<repo> && pytest tests/ -v` and touch the flag |
| "trd-coverage.json has failing rows" | Phase 1.5 mirror review found gaps | Read `trd-coverage.json`, implement gaps, mark passes |
| "phase2-progress.md row 7.5 still PENDING" | Worker skipped or crashed mid-pipeline | Re-invoke `/qship <TICKET>` — it'll pick up at the PENDING row |
| "Stale worktree — abandoned" | Worktree untouched for >4h | Either `rm -rf ${STATE_ROOT}/<TICKET>` to abandon, or `touch ${STATE_ROOT}/<TICKET>/phase2-progress.md` to revive |
