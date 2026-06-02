# Issue-source contract (tracker = `{{TRACKER_TYPE}}`)

This is the **single source of truth** for how every ticket-driven qship skill
(`qship`, `qshipmaster`, `qticket`, `qepic`, `qshiptrd`, `qshiptrdreview`,
`qshipexecutivetrd`, `qharness`, `qaddresstrdcomments`, `qtrduserstories`)
obtains, creates, transitions, and reads issues/TRDs. Those skills carry a
one-line pointer here instead of duplicating the rules.

**Your configured tracker is `{{TRACKER_TYPE}}`. Follow the matching section
below; ignore the others.** Skills that operate only on git/code/PRs
(`qcheck`, `qbug`, `qpr`, `qe2etest`, `qspinuplocal`, …) never read this file.

The five operations every skill needs (a skill uses whichever it requires):

| Op | Meaning |
|---|---|
| **FETCH** | read one issue's title + description + acceptance criteria by key |
| **CHILDREN** | list an epic's child issue keys |
| **CREATE** | open a new issue (returns its key/URL) |
| **TRANSITION/COMMENT** | move an issue's status or post a comment |
| **READ-TRD** | read a design doc / TRD the issue points at |

---

## `jira`

Credentials live in your connected **Atlassian MCP**, not in qship. Resolve the
cloud id once per run: call `getAccessibleAtlassianResources` (or use the
configured `{{COMPANY_SLUG_LOWER}}.atlassian.net`).

- **FETCH** → `getJiraIssue` with `issueIdOrKey=<KEY>`, `responseContentFormat=markdown`.
- **CHILDREN** → `searchJiraIssuesUsingJql` with `jql="parent = <KEY>"`, `fields=["summary"]`. No children ⇒ treat as a single Story/Task.
- **CREATE** → `createJiraIssue` (project = `{{JIRA_PROJECT_KEY}}`); capture the returned key + browse URL.
- **TRANSITION/COMMENT** → `transitionJiraIssue` / `addCommentToJiraIssue`.
- **READ-TRD** → Confluence: `getConfluencePage` (by id/URL the issue links to).

---

## `none`

There is **no tracker MCP**. The issue content comes from the user directly.

- **FETCH** → treat `$ARGUMENTS` as the source: either pasted ticket/spec text, or a path to a local markdown file (read it). For the unattended loop, read the first that exists: `{{STATE_ROOT}}/worktrees/<KEY>/ticket.md`, `…/USER_NOTE.md`, or `./<KEY>.md`. If nothing is provided, ask the user (or, in the persist loop, emit an empty manifest and stop).
- **CHILDREN** → no tracker to query. Read `{{STATE_ROOT}}/worktrees/<KEY>/children.txt` (one key per line) if present; otherwise treat the ticket as a single Story/Task (`NOT_AN_EPIC`).
- **CREATE** → don't call any API. Write the proposed issue as markdown (to the file path the user gave, or print it) for them to paste into their tracker.
- **TRANSITION/COMMENT** → **log** the intended transition/comment (don't perform it); there's nothing to call.
- **READ-TRD** → the TRD is a local file path or pasted text the user supplies; read/treat it directly. No Confluence.

In all cases a key like `{{JIRA_PROJECT_KEY}}-42` is just a **label** for branch
names and `{{STATE_ROOT}}` dirs — never something to fetch.

---

## `linear` *(reserved — not yet implemented)*

Falls back to `none` today. To implement, see **Adding a provider** below — the
Linear MCP exposes issue/project verbs (e.g. `get_issue`, `list_issues`,
`create_issue`, `update_issue`); an epic maps to a Linear **project/initiative**.

## `github` *(reserved — not yet implemented)*

Falls back to `none` today. To implement: the GitHub MCP / `gh` exposes
`issues` (`gh issue view/create/edit/comment`); an "epic" maps to a tracking
issue with a task-list or a milestone.

---

## Adding a provider (the ONLY places you touch)

The whole point of this file: a new tracker is **additive**, not a per-skill
edit. To add e.g. `linear`:

1. **`config.schema.json`** — add `"linear"` to the `tracker.tracker_type` enum.
2. **`setup.sh`** — in the tracker `case`, stop downgrading `linear` to `none`
   (move it into the `jira|none|linear)` accept arm); add it to the
   `/qship:configure` question in `skills/configure/SKILL.md`.
3. **This file** — replace the `linear` *reserved* stub above with a real
   section mapping the five operations to that provider's MCP tool names.
4. **`templates/skills/qship/hooks/qship-persist.sh`** — add a `linear)` arm to
   the two `case "{{TRACKER_TYPE}}"` blocks (AC fetch + epic children).

That's it — **no other skill changes**, because every ticket-driven skill only
holds a pointer to this file, and everything downstream operates on the resolved
spec text + git, not on the tracker. See `CONTRIBUTING.md` → "Adding an issue
tracker" for the same recipe.
