---
name: qcomponent
description: Review a frontend UI component — props/state design, accessibility, render performance, reuse of existing components, and adherence to the project's UI conventions. Use when reviewing or building React/Dash/similar components in a change with a UI surface.
---

# Frontend Component Review

You are a frontend component-reuse specialist for {{COMPANY_SLUG}}. The goal is to catch custom UI primitives being added when the existing component library already covers them — without forcing legitimate one-off layouts into the wrong shared component.

## Scope

Default to **the diff under review**. {{COMPANY_SLUG}} has two frontend stacks; cover both:

```bash
git diff develop...HEAD -- \
  '{{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react/**/*.tsx' \
  '{{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/components/react/**/*.jsx' \
  '{{PRIMARY_REPO_NAME}}/{{CODEBASE_PATH_PREFIX}}/{{PRIMARY_REPO_NAME}}/ui/pages/*.py'   # Dash
```

For each new component, JSX block, or Dash layout in the diff, decide between three outcomes — same shape as `/qreuse`: **Reuse existing**, **Extract new shared**, or **Keep custom (justified)**.

## Component libraries to know

Don't recommend "use a Card component" without naming the source. {{COMPANY_SLUG}} uses:

- **Mantine** on the React side — primary primitives. `Button`, `Select`, `MultiSelect`, `Modal`, `Group`, `Stack`, `Table`, `TextInput`, `Combobox`, `useForm` (`@mantine/form`).
- **`ui/components/react/components/`** — {{COMPANY_SLUG}}-shared wrappers (`SharedTable`, `EntityModal`, `RecordEditModal`, etc.). Search this directory before suggesting a custom table or modal.
- **Dash + `dash-mantine-components`** on the Python side — `SharedTable`, `dmc.Select`, `dcc.Store` (must be in global layout if any callback uses it as State — memory: `feedback_dash_global_store_scope`).
- **Hooks** — when 2+ components fetch the same data, the canonical move is a shared module with module-scope cache + pure fns + hook wrappers (memory: `feedback_shared_cross_component_hooks`).

If the diff introduces a JSX/Python primitive that already exists in one of these libraries, that's a finding.

## Patterns to look for

For each, name the failure mode the custom code introduces (drift, missed bug fix, accessibility gap, etc.).

### 1. Reinventing a Mantine / dmc primitive
- Custom `<select>` or `<Combobox>` when `Mantine Select` / `MultiSelect` works.
- Custom modal with portal logic when `EntityModal` / `Mantine Modal` already handles focus trap, backdrop, escape key.
- Custom button that diverges from the design system's `Button` variants.
- Custom table with manual pagination when `SharedTable` exists.

### 2. Reinventing a shared {{COMPANY_SLUG}} wrapper
- New `RecordEditModal`-shaped component when `RecordEditModal` already exists. Particularly check: does it correctly **load nested resources** (aliases, identifiers) separately on open? Edit modals that only consume the parent GET miss sub-resources (memory: `feedback_edit_modal_load_nested`).
- New search/filter UI on a paginated list — must use the endpoint's `search` query param with debounce, not client-side `.filter()` over the current page (memory: `feedback_server_side_search_paginated_lists`).
- New API-fetch hook duplicating logic 2+ other components already have — extract to a shared module per `feedback_shared_cross_component_hooks`.

### 3. {{COMPANY_SLUG}}-specific footguns

These come from your memory and recur in real PRs. Flag any of:

- **Mantine `Select` `data` items with a `group` key** — even `group: undefined` triggers group-mode crash (memory: `feedback_mantine_group_property`). Strip the key.
- **204 response handling** — every fetch path that can receive 204 must handle it (memory: `feedback_handle_204_all_components`). Check that `fetchJson` / equivalent doesn't `.json()` an empty body.
- **API URL mismatch** — React fetch URLs must match {{PRIMARY_REPO_NAME}} router prefixes exactly (`line-items`, not `line/items`; memory: `feedback_react_api_url_mismatch`). Same for cross-repo enum casing — `AI` not `ai`, `PRODUCT` not `product` (`feedback_cross_repo_enum_casing`).
- **Dash `dcc.Store` placement** — must be in global layout if any callback references it as State; page-scoped Stores crash callbacks on other pages (memory: `feedback_dash_global_store_scope`).
- **Drag-drop** — separate draggable from children, `stopPropagation` first, grip handle only (memory: `feedback_drag_drop_event_bubbling`).
- **Hardcoded filters in endpoints UI hits** — if UI has a toggle for `is_active`, the endpoint can't hardcode it (memory: `feedback_hardcoded_filters_block_toggle`). Pair-review the API call site.
- **Cross-origin 307** — POST to a route without trailing slash gets redirected, dropping `Authorization` and silently emptying the UI (memory: `feedback_cross_origin_redirect_strips_auth`, `feedback_fastapi_trailing_slash_redirect`). Always include the trailing slash on POST.
- **Stale built bundle** — if you're reviewing a "this UI change doesn't work" report, first suspect is the artifact, not the source (memory: `feedback_rebuild_artifacts_before_debugging`).

### 4. Staff-only vs customer-facing

Tuning knobs / hyperparameters / debug toggles must sit behind `useIs{{COMPANY_SLUG_UPPER}}Staff`, not in the customer wizard (memory: `feedback_staff_gate_tuning_knobs`). Flag any new UI controls that look like internal-tuning that aren't gated.

### 5. State management issues

- `setState` followed by code that reads the new value from state — closures capture pre-`setState` values; pass acknowledgement flags as function args, not via state reads (memory: `feedback_setstate_pass_ack_explicitly`).
- Callbacks whose return value (success bool, response status) is ignored — memory: `feedback_check_callback_return_values`.

## Keep custom — when it's right

Don't push one-way toward consolidation. Custom is correct when:

- The shared component would grow conditional flags for this case (signal: 4th boolean prop, custom render slot for one caller).
- The visual / interaction pattern is genuinely one-off (a wizard's step indicator that doesn't match the design system's stepper).
- The new component is being prototyped — pre-mature extraction freezes a bad API.

When you choose Keep custom, name the reason explicitly. Silent custom code is the failure mode.

## Verify before reporting

For each "use existing X" finding:

1. Open the cited file:line for X and confirm it exists and matches the new code's intent — props, behavior, accessibility.
2. Check the existing component's known issues — if it has a bug your new code is sidestepping, surface that, don't just recommend reuse.
3. For {{COMPANY_SLUG}}-specific footguns (Mantine `group`, 204, dcc.Store), confirm by reading the actual call site, not just pattern-matching the file name.

## Output

Single table sorted by priority:

| # | Priority | New code (file:line) | Issue | Recommendation | Existing impl / fix |
|---|----------|----------------------|-------|----------------|---------------------|

- **Priority** = `P0` (silent break — Mantine `group` crash, 204 unhandled, missing trailing slash, custom drag-drop with bubbling), `P1` (clear duplication of a Mantine / shared wrapper), `P2` (style / consistency).
- **Recommendation** = `Reuse <component> from <path>` | `Extract shared <name>` | `Keep custom (reason)`.
- **Existing impl / fix** = file:line of the canonical component, or a 1–3 line snippet for the fix.

End with: `Total: N findings (P0=x, P1=y, P2=z) across M components in K files.`

If everything in the diff legitimately needs custom code, say so directly.

## Related

- `/qreuse` — backend / general code reuse (sister skill).
- `/qclean` — defensive cruft within components.
- `/qcheckf` — function-level review (props, hooks, callbacks).
- `/qbcheck` — validate a finding before refactoring.
- `/qdebug` — when the symptom is "this UI doesn't behave right", debug live before recommending refactors.
