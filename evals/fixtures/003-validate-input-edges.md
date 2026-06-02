# EVAL-003 — Harden input validation on the widget-create endpoint

**Type:** Feature/hardening · **Complexity:** medium · **Surface:** backend API + validation

`POST /widgets` accepts a `name` and an optional `tags` array. It currently
trusts the input. Tighten validation so malformed input is rejected cleanly
instead of producing bad rows or 500s.

## Acceptance Criteria

1. `name` is required, 1–80 chars after trimming; empty/whitespace-only → 422.
2. `tags` (if present) is an array of ≤ 10 unique, non-empty strings; duplicates
   are de-duplicated, an over-limit array → 422.
3. Unicode names are accepted and stored intact (no mojibake).
4. A leading/trailing-whitespace name is trimmed before validation and storage.
5. Validation errors return a structured 422 body naming the offending field.

## Expected pipeline behavior

- Plan locates the existing validation/schema convention (e.g. the project's
  request-model pattern) and extends it rather than adding ad-hoc checks.
- Tests cover each boundary: empty name, 81-char name, 11 tags, duplicate tags,
  a Unicode name, and a whitespace-padded name — written before the fix.
- Phase-3 evidence includes curl blocks for at least the empty-name 422, the
  over-limit-tags 422, and a successful Unicode create round-tripped via a read.
- No acceptance criterion is marked done without a concrete observation.
