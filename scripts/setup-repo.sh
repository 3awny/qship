#!/usr/bin/env bash
# setup-repo.sh — one-time GitHub configuration for the qship repo.
#
# Applies open-source best-practice settings (merge strategy, branch ruleset,
# security features, metadata) via the `gh` CLI + REST API. Idempotent: safe to
# re-run; it patches settings and replaces the ruleset.
#
# Some features are free only on PUBLIC repos (branch rulesets, secret scanning,
# push protection). On a PRIVATE repo those steps are DEFERRED with a note — flip
# the repo to public and re-run this script to apply them.
#
# PREREQUISITES
#   1. The repo already exists on github.com and you've pushed `main`.
#   2. `gh` is authenticated to github.com (works even if you're also logged into
#      a GitHub Enterprise host):
#          gh auth status --hostname github.com
#          gh auth login  --hostname github.com   # if needed
#   3. You have admin rights on the repo (you do, as the owner).
#
# USAGE
#   bash scripts/setup-repo.sh                 # infers owner/repo from `origin`
#   bash scripts/setup-repo.sh 3awny/qship     # or pass it explicitly
#   DRY_RUN=1 bash scripts/setup-repo.sh       # print the gh calls, change nothing

set -uo pipefail

# ---- resolve target repo --------------------------------------------------
SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [[ -z "$SLUG" ]]; then
  echo "FATAL: couldn't determine owner/repo. Pass it: bash scripts/setup-repo.sh OWNER/REPO" >&2
  exit 2
fi

# ---- guard: gh must be authenticated to github.com ------------------------
# (Checks github.com specifically — not "the active host" — so this works even
#  when gh is also logged into a GitHub Enterprise host.)
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "FATAL: gh is not authenticated to github.com." >&2
  echo "       Run: gh auth login --hostname github.com   (then re-run this script)" >&2
  exit 2
fi

DRY_RUN="${DRY_RUN:-0}"
run() {
  if [[ "$DRY_RUN" == "1" ]]; then printf '  [dry-run] '; printf '%q ' "$@"; printf '\n'; return 0; fi
  "$@"
}
step() { echo; echo "==> $*"; }

echo "Configuring https://github.com/$SLUG"
[[ "$DRY_RUN" == "1" ]] && echo "(DRY RUN — no changes will be made)"

# Visibility gates the public-only / GitHub-Pro-only features below.
VISIBILITY="$(gh repo view "$SLUG" --json visibility -q .visibility 2>/dev/null | tr '[:upper:]' '[:lower:]')"
PUBLIC=0
[[ "$VISIBILITY" == "public" || "$DRY_RUN" == "1" ]] && PUBLIC=1

# ---- 1. merge strategy + branch hygiene + features ------------------------
step "Merge strategy, branch hygiene, repo features"
run gh repo edit "$SLUG" \
  --enable-squash-merge=true \
  --enable-merge-commit=false \
  --enable-rebase-merge=false \
  --delete-branch-on-merge=true \
  --enable-auto-merge=true \
  --enable-issues=true \
  --enable-wiki=false \
  --enable-projects=false \
  --description "Ticket → production-PR pipeline for Claude Code & Codex CLI, enforced by hooks. 21-skill pipeline, one configurator, adapts to any codebase." \
  --add-topic claude-code \
  --add-topic claude-code-plugin \
  --add-topic agent-skills \
  --add-topic codex-cli \
  --add-topic ai-agents \
  --add-topic developer-tools \
  --add-topic tdd

# Squash commit defaults aren't exposed by `gh repo edit` — set via the API.
step "Squash commit message = PR title + body"
run gh api -X PATCH "repos/$SLUG" \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=PR_BODY >/dev/null

# ---- 2. security features (free on PUBLIC repos only) ----------------------
if [[ "$PUBLIC" == "1" ]]; then
  step "Secret scanning + push protection"
  run gh api -X PATCH "repos/$SLUG" \
    -F 'security_and_analysis[secret_scanning][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null

  step "Dependabot alerts + automated security fixes"
  run gh api -X PUT "repos/$SLUG/vulnerability-alerts" >/dev/null
  run gh api -X PUT "repos/$SLUG/automated-security-fixes" >/dev/null
else
  step "Secret scanning + push protection — DEFERRED"
  echo "  repo is '$VISIBILITY'; secret scanning / push protection are free only on"
  echo "  public repos. Re-run this script after you flip it to public."
  echo "  (gitleaks already runs in CI regardless.)"
fi

# ---- 3. branch ruleset for the default branch -----------------------------
# Rules for a maintainer-gated repo (require CI, block force-push, block
# deletion, linear history) + a PR requirement that needs 1 approving review FROM
# A CODE OWNER (CODEOWNERS = @3awny, so only PRs YOU approve can merge). Direct
# pushes to the default branch are blocked for everyone EXCEPT the repo Admin role
# on the bypass list (you) — GitHub forbids approving your own PR, so the bypass is
# how you merge your own work / hotfixes without a second reviewer.
# Status-check contexts are the CI job *display names* in .github/workflows/ci.yml.
# Rulesets are free on PUBLIC repos (or GitHub Pro) — deferred on private.
if [[ "$PUBLIC" != "1" ]]; then
  step "Branch ruleset 'main protection' — DEFERRED"
  echo "  repo is '$VISIBILITY'; branch rulesets need a public repo (or GitHub Pro)."
  echo "  Re-run this script after you flip it to public to apply the ruleset."
else
  step "Branch ruleset on default branch (require CI, block force-push/deletion, linear history)"
  RULESET_JSON='{
    "name": "main protection",
    "target": "branch",
    "enforcement": "active",
    "bypass_actors": [
      { "actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always" }
    ],
    "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
    "rules": [
      { "type": "deletion" },
      { "type": "non_fast_forward" },
      { "type": "required_linear_history" },
      { "type": "pull_request", "parameters": {
          "required_approving_review_count": 1,
          "dismiss_stale_reviews_on_push": true,
          "require_code_owner_review": true,
          "require_last_push_approval": false,
          "required_review_thread_resolution": false
      }},
      { "type": "required_status_checks", "parameters": {
          "strict_required_status_checks_policy": true,
          "required_status_checks": [
            { "context": "Validate manifests + placeholders" },
            { "context": "Secret scan (gitleaks)" }
          ]
      }}
    ]
  }'

  # Replace any existing ruleset of the same name so re-runs stay idempotent.
  EXISTING_ID="$(gh api "repos/$SLUG/rulesets" -q '.[] | select(.name=="main protection") | .id' 2>/dev/null | head -1)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] would POST/PUT repos/$SLUG/rulesets"
  elif [[ -n "$EXISTING_ID" ]]; then
    echo "$RULESET_JSON" | gh api -X PUT "repos/$SLUG/rulesets/$EXISTING_ID" --input - >/dev/null && echo "  ✓ ruleset updated (#$EXISTING_ID)"
  else
    echo "$RULESET_JSON" | gh api -X POST "repos/$SLUG/rulesets" --input - >/dev/null && echo "  ✓ ruleset created"
  fi
fi

echo
echo "✅ Done. Verify in the browser:"
echo "   Settings → General → Pull Requests   (squash-only, auto-delete branches)"
echo "   Settings → Rules → Rulesets          (\"main protection\" — public repos only)"
echo "   Settings → Code security             (secret scanning, push protection, Dependabot)"
echo
echo "Note: required status checks ('Validate…', 'Secret scan…') only turn green"
echo "after CI has run on a PR. Open a throwaway PR to confirm the gate."
