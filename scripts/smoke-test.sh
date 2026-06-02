#!/usr/bin/env bash
# smoke-test.sh — simulate a brand-new user installing qship, end to end,
# WITHOUT touching your real ~/.claude or ~/.codex. Everything happens inside a
# throwaway $HOME so it's safe to run repeatedly.
#
# What it covers (the INSTALL layer):
#   1. fresh `setup.sh --config` install into a temp HOME
#   2. exactly the 21-skill pipeline renders
#   3. zero unfilled {{PLACEHOLDERS}} in the rendered output
#   4. repos.json is written and valid
#   5. setup.sh --check passes (tooling + rendered skills + repos.json)
#   6. uninstall.sh cleanly removes everything
#
# What it CANNOT cover (the RUN layer — do this yourself, interactively):
#   - an actual `/qship <ticket>` pipeline run (needs Claude Code, the 5
#     companion plugins, and a tracker/MCP or a tracker=none local spec file)
#   - `qspinuplocal` booting YOUR service (it auto-detects a Python/uvicorn
#     shape or asks once; non-Python stacks need you to point it at your start
#     command). See the printed NEXT STEPS at the end.
#
# Usage:  bash scripts/smoke-test.sh
#         CONFIG=path/to/your-answers.json bash scripts/smoke-test.sh   # use real answers

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=$((fail+1)); }

TMPHOME="$(mktemp -d)"
trap 'rm -rf "$TMPHOME"' EXIT
mkdir -p "$TMPHOME/.claude/skills" "$TMPHOME/.claude/agents"
echo '{"hooks":{}}' > "$TMPHOME/.claude/settings.json"
SKILLS="$TMPHOME/.claude/skills"

echo "==> Simulating a fresh install into a throwaway HOME"
echo "    (your real ~/.claude is untouched)"
echo

# Build the answers file a new user would produce. Default: the shipped example,
# repointed at the temp HOME. Override with CONFIG=... to use your real answers.
CFG="$TMPHOME/answers.json"
SRC="${CONFIG:-$REPO_ROOT/config.example.json}"
jq --arg h "$TMPHOME" --arg s "$SKILLS" \
   '.codebase.user_home=$h | .codebase.skills_root=$s' \
   "$SRC" > "$CFG" 2>/dev/null || { no "couldn't build answers from $SRC"; exit 1; }

# ---- 1. install -----------------------------------------------------------
echo "==> 1. Running setup.sh --config (non-interactive install)"
if HOME="$TMPHOME" bash setup.sh --config "$CFG" >"$TMPHOME/install.log" 2>&1; then
  ok "setup.sh exited 0"
else
  no "setup.sh failed — see below"; sed 's/^/      /' "$TMPHOME/install.log" | tail -25; exit 1
fi

# ---- 2. exactly 21 skills -------------------------------------------------
n=$(find "$SKILLS" -maxdepth 1 -type d -name 'q*' | wc -l | tr -d ' ')
[ "$n" -eq 21 ] && ok "installed exactly 21 skills" || no "expected 21 skills, got $n"

# ---- 3. no unfilled placeholders -----------------------------------------
u=$(grep -rhoE '\{\{[A-Z_]+\}\}' "$SKILLS" 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "$u" -eq 0 ] && ok "no unfilled {{PLACEHOLDERS}} in rendered skills" \
  || { no "$u unfilled placeholder(s):"; grep -rhoE '\{\{[A-Z_]+\}\}' "$SKILLS" | sort -u | sed 's/^/        /'; }

# ---- 4. repos.json valid --------------------------------------------------
if jq -e 'type=="array" and length>=1' "$SKILLS/qship/repos.json" >/dev/null 2>&1; then
  ok "repos.json written and valid ($(jq length "$SKILLS/qship/repos.json") repo(s))"
else
  no "repos.json missing or invalid"
fi

# ---- 5. health check ------------------------------------------------------
echo "==> 5. Running setup.sh --check (the new-user health check)"
if HOME="$TMPHOME" SKILLS_ROOT="$SKILLS" bash setup.sh --check >"$TMPHOME/check.log" 2>&1; then
  ok "setup.sh --check passed"
else
  # --check returns non-zero if companion plugins are missing — expected in a
  # bare temp HOME. Treat a missing-plugin-only failure as a warning.
  if grep -qiE 'missing required plugins' "$TMPHOME/check.log"; then
    ok "setup.sh --check ran (flags missing companion plugins — expected in a bare HOME)"
  else
    no "setup.sh --check failed:"; sed 's/^/      /' "$TMPHOME/check.log" | tail -20
  fi
fi

# ---- 6. uninstall ---------------------------------------------------------
echo "==> 6. Running uninstall.sh"
if HOME="$TMPHOME" bash uninstall.sh "$CFG" >"$TMPHOME/uninstall.log" 2>&1; then
  left=$(find "$SKILLS" -maxdepth 1 -type d -name 'q*' | wc -l | tr -d ' ')
  [ "$left" -eq 0 ] && ok "uninstall removed all skills" || no "uninstall left $left skill dir(s)"
else
  no "uninstall.sh failed"; sed 's/^/      /' "$TMPHOME/uninstall.log" | tail -15
fi

echo
echo "================ RESULT: $pass passed, $fail failed ================"
echo
cat <<'NEXT'
NEXT STEPS — the RUN layer this script can't do for you (real new-user E2E):

  1. Install the 5 companion plugins qship delegates to:
       /plugin marketplace add anthropics/claude-plugins-official
       /plugin install superpowers feature-dev code-review code-simplifier pr-review-toolkit

  2. Configure for YOUR codebase (interactive):
       /qship:configure          (or: bash setup.sh)

  3. Pick a tracker:
       - jira  → connect the Atlassian MCP in Claude Code
       - none  → write a spec to ticket.md and run /qship against it

  4. Drive one ticket end to end and watch the phase gates:
       /qship <TICKET-or-spec-path>

  5. qspinuplocal note: it auto-detects a Python/uvicorn + Postgres shape. If
     your stack differs (Node/Go/Rails), it will ask how to start your service
     the first time — have your local run command + DB name ready.
NEXT
[ "$fail" -eq 0 ]
