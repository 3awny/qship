# qship — completion report format (reference)

Extracted from `SKILL.md`. Read at the end of a run to format the results
summary and clean up worktrees.

---

## Completion Report

After the pipeline finishes (for all tickets), display a summary.

### Summary Table

**For standalone tickets:**
```
Pipeline Results
================

| Ticket   | Branch                          | PR URL(s)                             | Status  |
|----------|---------------------------------|---------------------------------------|---------|
| {{JIRA_PROJECT_KEY}}-42   | {{JIRA_PROJECT_KEY}}-42-fix-login-timeout        | {{PRIMARY_REPO_NAME}}: https://github.com/.../pull/1 | Success |
| {{JIRA_PROJECT_KEY}}-42   | {{JIRA_PROJECT_KEY}}-42-fix-login-timeout        | {{PRIMARY_REPO_NAME}}: https://github.com/.../pull/2 | Success |
```

**For epics (consolidated PRs):**
```
Pipeline Results — Epic {{JIRA_PROJECT_KEY}}-245
================================

Consolidated PRs (one per repo):
| Repo           | Branch                          | PR URL                                | Stories Included          |
|----------------|---------------------------------|---------------------------------------|---------------------------|
| {{PRIMARY_REPO_NAME}}        | {{JIRA_PROJECT_KEY}}-245-catalog-system-ui       | https://github.com/.../pull/1         | {{JIRA_PROJECT_KEY}}-247                   |
| {{PRIMARY_REPO_NAME}}    | {{JIRA_PROJECT_KEY}}-245-catalog-system-ui       | https://github.com/.../pull/2         | {{JIRA_PROJECT_KEY}}-248-254 (7 stories)   |

Story Status:
| Story    | Summary                           | Repo          | Status      |
|----------|-----------------------------------|---------------|-------------|
| {{JIRA_PROJECT_KEY}}-246  | Backend API amendments            | {{PRIMARY_REPO_NAME}}   | Pre-existing |
| {{JIRA_PROJECT_KEY}}-247  | record_group_id filter             | {{PRIMARY_REPO_NAME}}       | Implemented  |
| {{JIRA_PROJECT_KEY}}-248  | RecordManagement React           | {{PRIMARY_REPO_NAME}}   | Implemented  |
| ...      | ...                               | ...           | ...          |
```

For failed tickets:
```
| {{JIRA_PROJECT_KEY}}-99   | (not created)                   | (none)                                | FAILED  |
```

Include error details for any failed ticket beneath the table.

### Worktree Cleanup

After reporting results, clean up all worktrees:

```bash
cd {{CODEBASE_ROOT}} && git worktree remove {{STATE_ROOT}}/worktrees/<TICKET_ID>
```

Repeat for each ticket. Then remove the base directory if empty:
```bash
rmdir {{STATE_ROOT}}/worktrees 2>/dev/null
```

If a worktree removal fails (e.g., uncommitted changes from a failed pipeline), warn the user:
```
Could not remove worktree at {{STATE_ROOT}}/worktrees/<TICKET_ID>.
Manual cleanup: git -C {{CODEBASE_ROOT}} worktree remove --force {{STATE_ROOT}}/worktrees/<TICKET_ID>
```

