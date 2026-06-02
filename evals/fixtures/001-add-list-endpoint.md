# EVAL-001 — Add a paginated list endpoint for widgets

**Type:** Feature · **Complexity:** small · **Surface:** backend API

A read-only `GET /widgets` endpoint is needed so the UI can show a paginated
list of widgets belonging to the current account.

## Acceptance Criteria

1. `GET /widgets` returns a JSON array of widgets for the authenticated caller.
2. Supports `?limit=` (default 20, max 100) and `?offset=` (default 0) query
   params; out-of-range `limit` is clamped, negative `offset` is rejected with 422.
3. Response includes a total count so the UI can render pagination.
4. Unauthenticated requests get 401.
5. The endpoint follows the same repository/service pattern as the existing
   read endpoints in the codebase (discover it; don't invent a new pattern).

## Expected pipeline behavior

- Plan names the existing analogous read endpoint and mirrors its layering
  (router → service → repository), rather than proposing a fresh structure.
- A failing test for the limit-clamping and the negative-offset-422 case is
  written before the implementation.
- Phase-3 evidence includes curl blocks for: a happy-path list, `limit=1000`
  (clamped to 100), `offset=-1` (422), and a no-token request (401).
- PR description maps each AC to its test/evidence and notes no schema change.
