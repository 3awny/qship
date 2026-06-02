---
name: Bug report
about: Something broke — a skill misbehaved, install failed, lint missed a leak
title: '[bug] '
labels: bug
---

## What happened

<!-- One-sentence summary. -->

## Reproduction

1.
2.
3.

## Expected

<!-- What did you expect to see instead. -->

## Environment

- OS: macOS / Linux / WSL (delete as appropriate)
- Bash version: `bash --version | head -1`
- Claude Code version: `claude --version`
- Codex CLI version (if relevant): `codex --version`
- qship commit: `git -C ~/work/qship rev-parse HEAD`

## Logs / output

```
<!-- paste log output, error messages, etc. Use ``` fences. -->
```

## Did you check

- [ ] `bash scripts/validate-placeholders.sh` (any unresolved placeholders?)
- [ ] `bash scripts/lint-forbidden.sh` (any leaked customer data — see CONTRIBUTING.md)
- [ ] `claude plugin validate ~/work/qship/` (manifest valid?)
- [ ] `bash -n setup.sh` (shell syntax OK?)

---

⛔ **Do NOT paste real customer data, real internal hostnames, real email addresses, or real ticket numbers in this issue.** Scrub them first. If the bug is specifically about a real leak, open a private security advisory instead.
