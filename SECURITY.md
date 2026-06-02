# Security Policy

## Reporting a vulnerability or a data leak

**Do not open a public issue for anything sensitive.** That includes real
customer data / secrets / PII visible in a rendered template, *and* ordinary
security vulnerabilities in the shipped scripts or hooks.

Report privately via either:

- **GitHub private security advisory** — https://github.com/3awny/qship/security/advisories/new (preferred)
- **Email** — ahmedawny.one@gmail.com with subject `[qship security]`

Please include: what you found, the file/path (or a minimal repro), and — for a
leak — *describe* it rather than pasting the leaked value (a public-bound report
that quotes the secret just re-leaks it).

We aim to acknowledge within a few days. There's no bug-bounty; this is a
community project.

## What counts as a security issue here

qship ships **no runtime service** — it's a catalogue of Claude Code / Codex
skills, bash hooks, and an installer. The relevant classes are:

1. **Leaked sensitive data in published templates** — real customer/company
   names, internal hostnames, credentials, real ticket/PO/UUID values. The repo
   defends against this with `scripts/lint-forbidden.sh` (maintainer deny-list,
   114 patterns), `scripts/check-no-local-leak.sh` (contributor self-check), a
   pre-commit hook, gitleaks in CI, and a squashed single-commit history. If you
   find something that slipped through, report it privately as above.
2. **Vulnerabilities in the bundled scripts/hooks** a user inherits by
   installing — command injection, unsafe `eval`/`source`, unquoted expansion,
   `curl | bash`, destructive `rm`, secrets written world-readable, etc.
3. **The autonomy surface.** qship's unattended loop spawns
   `claude --print --dangerously-skip-permissions`; see the "Security &
   autonomy" section of the README. Reports about that surface are welcome.

## What is *not* in scope

- **Credentials are never stored by qship.** It references env-var *names*
  (`DATABASE_URL`, `DB_PROVIDER_API_KEY`, etc.) and your Jira credential lives in
  your Atlassian MCP connection, not here. A finding that "qship reads a token
  from your `.env`" is by design — keep your `.env` gitignored (it is, by
  default).
- The example/placeholder values in `config.example.json` (`acme`, `your-org`,
  `PROJ`, `example-postgres.com`, …) are intentional dummies.

## Hardening you should enable on your fork

After publishing a fork, turn on GitHub **Secret Scanning** + **Push
Protection** (Settings → Code security) as a backstop, and keep the pre-commit
hook installed (`git config core.hooksPath scripts/githooks`).

## Supported versions

This is pre-1.x community software; only the latest `main` is supported.
Security fixes land on `main`; there are no backports.
