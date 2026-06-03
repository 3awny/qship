#!/usr/bin/env bash
# setup.sh — interactive installer for qship.
#
# Walks the user through a ~15-question questionnaire, then renders every
# template under templates/ via envsubst into ~/.claude/skills/<name>/, links
# them into ~/.codex/skills/ if Codex CLI is detected, merges hook commands
# into ~/.claude/settings.json (idempotent), and prints a quickstart.
#
# Run from the repo root:   bash setup.sh
# Non-interactive / CI:     bash setup.sh --config answers/my-answers.env
# Dry-run (no writes):       bash setup.sh --dry-run

set -euo pipefail

# --- Platform guard: native Windows is not supported -------------------------
# qship shells out to POSIX tools (jq, envsubst, git, perl, psql) and POSIX bash
# hooks, so native Windows shells (PowerShell, cmd, Git Bash, MSYS, Cygwin) won't
# work. On Windows, run qship inside WSL2 — a real Linux environment where
# everything behaves exactly as on Linux. WSL itself reports `uname -s` = "Linux",
# so it passes this guard and runs normally.
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN* | Windows*)
    cat >&2 <<'WIN'
qship needs a POSIX/Linux environment — native Windows (PowerShell, cmd, Git Bash,
MSYS, Cygwin) is not supported. Run it inside WSL2:

  1. In an admin PowerShell:  wsl --install            (reboot if prompted)
  2. Open "Ubuntu" from Start, then install deps:
       sudo apt-get update && sudo apt-get install -y jq gettext
  3. Re-run qship inside WSL:  bash setup.sh

WSL2 guide: https://learn.microsoft.com/windows/wsl/install
WIN
    exit 1
    ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_ROOT="$REPO_ROOT/templates"
DEPS_ROOT="$REPO_ROOT/deps"

# Claude Code's config dir. Honors CLAUDE_CONFIG_DIR (Claude Code's own env var)
# so the agent, settings.json hooks, and plugin lookup land in the right place —
# and so an install can be fully isolated (e.g. CLAUDE_CONFIG_DIR=/tmp/x for tests)
# instead of always writing to the live ~/.claude.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

DRY_RUN=false
CONFIG_FILE=""
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--config FILE] [--dry-run] [--check]

  --config FILE   Load answers from FILE (auto-detect .json or .env) instead
                  of prompting. JSON format is preferred and matches
                  ./config.example.json — copy that to config.json, edit, and
                  pass --config config.json for non-interactive installs.
  --dry-run       Show what would be installed; write nothing.
  --check         Verify an existing install (no prompts, no writes): tooling,
                  rendered skills, unfilled placeholders, repos.json, and the
                  required external plugins. Exits 0 if healthy, 1 if not.

If --config is not given but ./config.json exists at the repo root, it is
used automatically (with prompts for any missing keys).
EOF
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m %s\n' "$*"; }
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
fatal(){ err "$*"; exit 1; }

# missing_external_plugins — emit (TAB-separated) the rows from deps/plugin-marketplaces.txt
# whose plugin is NOT present in ~/.claude/plugins/installed_plugins.json.
# If we can't read that file (older Claude Code, or jq missing), emit ALL rows
# so the user still sees the full install block (fail safe, not silent).
missing_external_plugins() {
  local plugins_file="$DEPS_ROOT/plugin-marketplaces.txt"
  local installed="$CLAUDE_DIR/plugins/installed_plugins.json"
  [[ -f "$plugins_file" ]] || return 0
  local can_detect=true
  { [[ -f "$installed" ]] && command -v jq >/dev/null 2>&1; } || can_detect=false
  while IFS=$'\t' read -r marketplace install_cmd description; do
    [[ -z "${marketplace:-}" || "${marketplace:0:1}" == "#" ]] && continue
    if $can_detect && jq -e --arg p "$install_cmd" \
         '.plugins | keys[] | select(startswith($p + "@"))' "$installed" >/dev/null 2>&1; then
      continue   # installed → skip
    fi
    printf '%s\t%s\t%s\n' "$marketplace" "$install_cmd" "$description"
  done < "$plugins_file"
  return 0
}

# run_check — non-destructive health check of an existing install.
run_check() {
  local skills_root="${SKILLS_ROOT:-$CLAUDE_DIR/skills}"
  local problems=0
  log "==> qship health check"
  log

  # 1. Tooling
  for tool in jq envsubst git; do
    if command -v "$tool" >/dev/null 2>&1; then ok "$tool on PATH"
    else err "$tool missing"; problems=$((problems+1)); fi
  done
  command -v gh    >/dev/null 2>&1 || warn "gh CLI missing — Phase 4 PR creation won't work"
  command -v claude >/dev/null 2>&1 || warn "claude CLI missing"

  # 2. Rendered skills present
  if [[ -d "$skills_root/qship" ]]; then ok "qship skill installed at $skills_root/qship"
  else err "qship not installed under $skills_root — run /qship:configure (or setup.sh)"; problems=$((problems+1)); fi
  local skill_count; skill_count=$(find "$skills_root" -maxdepth 1 -type d -name 'q*' 2>/dev/null | wc -l | tr -d ' ')
  log "    $skill_count q* skills installed"

  # 3. No unfilled placeholders (grep exits 1 when none found — that's the good case)
  local unfilled; unfilled=$( { grep -rEoh '\{\{[A-Z_]+\}\}' "$skills_root"/q*/ 2>/dev/null || true; } | sort -u | grep -c . || true)
  if [[ "${unfilled:-0}" -eq 0 ]]; then ok "no unfilled {{PLACEHOLDERS}} in rendered skills"
  else err "$unfilled unfilled placeholder(s) — re-run /qship:configure"; problems=$((problems+1)); fi

  # 4. repos.json valid
  local repos="$skills_root/qship/repos.json"
  if [[ -f "$repos" ]] && jq -e 'type=="array" and length>=1' "$repos" >/dev/null 2>&1; then
    ok "repos.json valid ($(jq -r 'length' "$repos") repo(s), primary: $(jq -r '(.[]|select(.is_primary==true)|.name)//.[0].name' "$repos"))"
  else err "repos.json missing or invalid at $repos"; problems=$((problems+1)); fi

  # 5. Required external plugins
  local missing; missing="$(missing_external_plugins || true)"
  if [[ -z "$missing" ]]; then
    ok "all required external plugins present"
  else
    err "missing required plugins (skills will fail mid-pipeline without these):"
    while IFS=$'\t' read -r mk cmd desc; do
      [[ -z "$mk" ]] && continue
      log "      /plugin marketplace add $mk  &&  /plugin install $cmd"
    done <<< "$missing"
    problems=$((problems+1))
  fi

  log
  if [[ "$problems" -eq 0 ]]; then ok "qship is healthy — try: /qship <TICKET-ID>"; return 0
  else err "$problems problem(s) found — see above"; return 1; fi
}

if $CHECK_ONLY; then
  DEPS_ROOT="${DEPS_ROOT:-$REPO_ROOT/deps}"
  run_check; exit $?
fi

log "==> Pre-flight"
command -v jq        >/dev/null || fatal "jq required (brew install jq)"
command -v envsubst  >/dev/null || fatal "envsubst required (gettext / brew install gettext)"
command -v git       >/dev/null || fatal "git required"
command -v gh        >/dev/null || warn  "gh CLI not found — Phase 4 PR creation will not work until you install it"
command -v claude    >/dev/null || warn  "claude CLI not found — qship is designed for Claude Code"
command -v codex     >/dev/null || warn  "codex CLI not found — provider=codex / reviewer=codex paths will be disabled"

[[ -d "$CLAUDE_DIR" ]] || fatal "$CLAUDE_DIR not found — install Claude Code first (or set CLAUDE_CONFIG_DIR)"

ok "Pre-flight checks passed"

# ---------------------------------------------------------------------------
# 2. Questionnaire
# ---------------------------------------------------------------------------
prompt_or_default() {
  local var_name="$1"; local question="$2"; local default="$3"
  # In NONINTERACTIVE mode, accept whatever the config file said — including
  # an explicit empty string (user opted out of an optional field).  Only
  # fall back to default when the var is genuinely UNSET (config silent on it).
  # `${!var+isset}` distinguishes unset from empty without bash 4 indirection.
  if $NONINTERACTIVE; then
    eval "local is_set=\${${var_name}+isset}"
    if [[ -n "${is_set:-}" ]]; then
      eval "echo \"\${${var_name}}\""
      return
    fi
    echo "$default"; return
  fi
  # INTERACTIVE: prompt unless the var is already set to a non-empty value
  # (from a previous run's answers/last-run.json or env).
  local current_value="${!var_name:-}"
  [[ -n "$current_value" ]] && { echo "$current_value"; return; }
  local prompt
  if [[ -n "$default" ]]; then prompt="$question [$default]: "
  else prompt="$question: "; fi
  read -r -p "$prompt" answer </dev/tty
  echo "${answer:-$default}"
}

prompt_yn() {
  local var_name="$1"; local question="$2"; local default="$3"
  local current_value="${!var_name:-}"
  [[ -n "$current_value" ]] && { echo "$current_value"; return; }
  if $NONINTERACTIVE; then echo "$default"; return; fi
  local answer
  read -r -p "$question [$default] (y/n): " answer </dev/tty
  case "${answer:-$default}" in
    y|Y|yes|YES) echo "y" ;;
    *) echo "n" ;;
  esac
}

NONINTERACTIVE=false

# Auto-pick ./config.json if no --config given and it exists.
if [[ -z "$CONFIG_FILE" && -f "$REPO_ROOT/config.json" ]]; then
  CONFIG_FILE="$REPO_ROOT/config.json"
  log "Found $CONFIG_FILE — using it (will prompt for any missing keys)."
fi

# load_json_config — read every key from the schema'd JSON into env vars.
# Nested keys flatten to top-level vars (e.g. .codebase.codebase_root → CODEBASE_ROOT).
# The `repos` array is special-cased — it's exported as REPOS_JSON (the literal
# JSON array string) so downstream skills can jq it at runtime, plus a few
# derived helpers (REPO_COUNT, PRIMARY_REPO_NAME).
load_json_config() {
  local f="$1"
  command -v jq >/dev/null || fatal "jq required to read JSON config"
  # Scalar leaves (skipping the `repos` array) get exported as flat vars.
  # Skip metadata keys starting with _ or $.
  while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^[_$] ]] && continue
    local var_name; var_name="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    # Harden: only export plain UPPER_SNAKE identifiers, and never overwrite a
    # shell-sensitive variable. Defends against a malicious config key (e.g.
    # "ld_preload" / "path") that uppercases into PATH / LD_PRELOAD / IFS.
    case "$var_name" in
      ''|*[!A-Z0-9_]*|PATH|HOME|IFS|ENV|BASH_ENV|SHELL|PS4|LD_PRELOAD|LD_LIBRARY_PATH|DYLD_*)
        warn "ignoring unexpected/unsafe config key: $key"; continue ;;
    esac
    export "$var_name=$value"
  done < <(jq -r '
    paths(type != "object" and type != "array") as $p
    | select($p[0] != "repos")
    | $p[-1] as $leaf
    | select(($leaf | tostring) | test("^[_$]") | not)
    | [$leaf, (getpath($p) // "" | tostring)]
    | @tsv
  ' "$f")
  # repos[] — export as JSON string + helpers
  REPOS_JSON="$(jq -c '.repos // []' "$f")"
  export REPOS_JSON
  REPO_COUNT="$(jq -r '.repos | length' "$f")"
  export REPO_COUNT
  PRIMARY_REPO_NAME="$(jq -r '(.repos[]? | select(.is_primary == true) | .name) // (.repos[0].name // "")' "$f")"
  export PRIMARY_REPO_NAME
  # Booleans: JSON true/false → bash y/n
  for boolvar in CODEX_INTEGRATION_ENABLED; do
    case "${!boolvar:-}" in
      true)  export "$boolvar=y" ;;
      false) export "$boolvar=n" ;;
    esac
  done
}

# prompt_repos — interactive loop to build a JSON array of repo objects.
# Each repo gets {name, kind, schema, package, has_migrations, runs_locally, is_primary, port}.
# In non-interactive mode, REPOS_JSON (already set by load_json_config) wins.
prompt_repos() {
  if $NONINTERACTIVE && [[ -n "${REPOS_JSON:-}" && "$REPOS_JSON" != "[]" && "$REPOS_JSON" != "null" ]]; then
    return
  fi
  # Non-interactive mode but config had no repos[] (or an empty array): fall
  # back to a single default repo derived from CODEBASE_ROOT rather than
  # blocking on /dev/tty reads. The user can re-run /qship:configure later.
  if $NONINTERACTIVE; then
    warn "Config has no repos[] — defaulting to single-repo install named '$(basename "$CODEBASE_ROOT")'."
    REPOS_JSON="$(jq -nc --arg name "$(basename "$CODEBASE_ROOT")" '[{name:$name, kind:"monolith", schema:null, package:null, has_migrations:false, runs_locally:false, is_primary:true, port:null}]')"
    REPO_COUNT=1
    PRIMARY_REPO_NAME="$(basename "$CODEBASE_ROOT")"
    export REPOS_JSON REPO_COUNT PRIMARY_REPO_NAME
    return
  fi
  log
  log "==> Tell me about your repos. Add one entry per repo directory under \$CODEBASE_ROOT."
  log "    Single-repo project? Add one and say 'done'. 12 services? Add twelve."
  log
  local repos_json="[]"
  local idx=0
  while :; do
    local default_primary; default_primary="$([[ $idx -eq 0 ]] && echo y || echo n)"
    local name; read -r -p "  Repo #$((idx+1)) directory name (blank to finish): " name </dev/tty
    [[ -z "$name" ]] && break
    local kind;            read -r -p "    Kind [monolith/service/library/gateway/frontend/worker/test-harness/other] (default: service): " kind </dev/tty
    kind="${kind:-service}"
    local schema;          read -r -p "    SQL schema this repo owns (blank if N/A): " schema </dev/tty
    local package;         read -r -p "    Python/JS package name for imports inside this repo (blank if N/A): " package </dev/tty
    local has_migrations;  read -r -p "    Does this repo have its own migrations? (y/n, default n): " has_migrations </dev/tty
    has_migrations="${has_migrations:-n}"
    local runs_locally;    read -r -p "    Does qspinuplocal start this repo's process? (y/n, default n): " runs_locally </dev/tty
    runs_locally="${runs_locally:-n}"
    local is_primary;      read -r -p "    Is this your PRIMARY repo? (y/n, default $default_primary): " is_primary </dev/tty
    is_primary="${is_primary:-$default_primary}"
    local port;            read -r -p "    Default local dev port (blank if N/A): " port </dev/tty
    local port_json
    if [[ -z "$port" ]]; then port_json='null'; else port_json="$port"; fi
    local schema_json package_json
    schema_json=$(jq -Rn --arg v "$schema" 'if $v == "" then null else $v end')
    package_json=$(jq -Rn --arg v "$package" 'if $v == "" then null else $v end')
    repos_json="$(jq -c \
      --arg name "$name" --arg kind "$kind" \
      --argjson schema "$schema_json" --argjson package "$package_json" \
      --argjson has_migrations "$([[ "$has_migrations" =~ ^[yY] ]] && echo true || echo false)" \
      --argjson runs_locally "$([[ "$runs_locally" =~ ^[yY] ]] && echo true || echo false)" \
      --argjson is_primary "$([[ "$is_primary" =~ ^[yY] ]] && echo true || echo false)" \
      --argjson port "$port_json" \
      '. += [{name:$name, kind:$kind, schema:$schema, package:$package, has_migrations:$has_migrations, runs_locally:$runs_locally, is_primary:$is_primary, port:$port}]' \
      <<<"$repos_json")"
    idx=$((idx+1))
  done
  if [[ $idx -eq 0 ]]; then
    warn "No repos defined — adding a single default repo named '$(basename "$CODEBASE_ROOT")'."
    repos_json="$(jq -nc --arg name "$(basename "$CODEBASE_ROOT")" '[{name:$name, kind:"monolith", schema:null, package:null, has_migrations:false, runs_locally:false, is_primary:true, port:null}]')"
  fi
  REPOS_JSON="$repos_json"
  REPO_COUNT="$(jq -r 'length' <<<"$repos_json")"
  PRIMARY_REPO_NAME="$(jq -r '(.[]? | select(.is_primary==true) | .name) // (.[0].name // "")' <<<"$repos_json")"
  export REPOS_JSON REPO_COUNT PRIMARY_REPO_NAME
}

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || fatal "Config file not found: $CONFIG_FILE"
  case "$CONFIG_FILE" in
    *.json)
      load_json_config "$CONFIG_FILE"
      ok "Loaded JSON config from $CONFIG_FILE"
      ;;
    *)
      # The legacy `.env` path used `source`, which executes the file — arbitrary
      # code execution if the path/content is attacker-controlled. Removed:
      # JSON is the only supported config format.
      fatal "Config must be a .json file (got: $CONFIG_FILE). Copy config.example.json, edit it, and pass --config that.json."
      ;;
  esac
  NONINTERACTIVE=true
fi

log
log "==> Questionnaire (press Enter to accept the [default])"
log
USER_HOME="${USER_HOME:-$HOME}"
SKILLS_ROOT="${SKILLS_ROOT:-$HOME/.claude/skills}"

CODEBASE_ROOT="$(prompt_or_default CODEBASE_ROOT 'Absolute path to your monorepo root' "$HOME/work/$(basename "$PWD")")"
CODEBASE_DIR_NAME="$(basename "$CODEBASE_ROOT")"
COMPANY_SLUG="$(prompt_or_default COMPANY_SLUG 'Company / project short slug (used in /tmp/<slug>-…)' 'acme')"
COMPANY_SLUG_LOWER="$(echo "$COMPANY_SLUG" | tr '[:upper:]' '[:lower:]')"
COMPANY_SLUG_UPPER="$(echo "$COMPANY_SLUG" | tr '[:lower:]' '[:upper:]')"
CODEBASE_PATH_PREFIX="$(prompt_or_default CODEBASE_PATH_PREFIX 'Top-level source-tree directory inside each repo (the path prefix used in narrative file references, e.g. src/, app/, packages/)' 'src')"
COMPANY_DOMAIN="$(prompt_or_default COMPANY_DOMAIN 'Company domain (used in narrative — leave blank to drop)' '')"
# Issue tracker: jira (Atlassian MCP) or none (paste the ticket / TRD text or a
# file path; ticket-driven skills skip all tracker MCP calls). linear/github
# are reserved for future provider support — accept them but treat as 'none'
# (no provider integration shipped yet) so early adopters can opt in by name.
TRACKER_TYPE="$(prompt_or_default TRACKER_TYPE 'Issue tracker [jira/none]  (none = paste ticket text or a file path; no Jira MCP needed)' 'jira')"
case "$TRACKER_TYPE" in
  jira|none) : ;;
  linear|github) warn "tracker '$TRACKER_TYPE' has no provider integration yet — treating as 'none' (paste/file input)."; TRACKER_TYPE="none" ;;
  *) warn "unknown tracker '$TRACKER_TYPE' — defaulting to 'none'."; TRACKER_TYPE="none" ;;
esac
JIRA_PROJECT_KEY="$(prompt_or_default JIRA_PROJECT_KEY 'Ticket-key prefix used in IDs / branch names (e.g. PROJ, TASK, ABC)' 'PROJ')"
GH_HOST="$(prompt_or_default GH_HOST 'GitHub host (github.com or your GHE hostname)' 'github.com')"
GH_ORG="$(prompt_or_default GH_ORG 'GitHub org name' 'your-org')"
DEFAULT_BRANCH="$(prompt_or_default DEFAULT_BRANCH 'Default base branch' 'develop')"

# Repo list — flexible array. Single-repo, 2-repo split, 12-service monorepo all OK.
prompt_repos

PRIMARY_LANGUAGE="$(prompt_or_default PRIMARY_LANGUAGE 'Primary language [python/typescript/go/mixed]' 'python')"
case "$PRIMARY_LANGUAGE" in
  python)     DEFAULT_TEST='pytest tests/ -v'; DEFAULT_LINT='python -m flake8 . --max-line-length=120'; DEFAULT_FORMAT='python -m black . && python -m isort .' ;;
  typescript) DEFAULT_TEST='npm test';         DEFAULT_LINT='npm run lint';                          DEFAULT_FORMAT='npm run format' ;;
  go)         DEFAULT_TEST='go test ./...';    DEFAULT_LINT='golangci-lint run';                      DEFAULT_FORMAT='gofmt -w .' ;;
  *)          DEFAULT_TEST='echo "configure TEST_COMMAND"'; DEFAULT_LINT='echo "configure LINT_COMMAND"'; DEFAULT_FORMAT='echo "configure FORMAT_COMMAND"' ;;
esac
TEST_COMMAND="$(prompt_or_default TEST_COMMAND 'Test command' "$DEFAULT_TEST")"
LINT_COMMAND="$(prompt_or_default LINT_COMMAND 'Lint command' "$DEFAULT_LINT")"
FORMAT_COMMAND="$(prompt_or_default FORMAT_COMMAND 'Format command' "$DEFAULT_FORMAT")"

# Opt-in features FIRST — they gate which later questions are even worth asking.
# (e.g. don't prompt for Postgres details if the user wants neither the local
# stack nor migrations.)
log
log "==> Optional integration"
log
# qship installs the full pipeline (21 skills) every time — all are reachable
# from the qship/qshipmaster pipeline, so there are no skill-selection toggles.
CODEX_INTEGRATION_ENABLED="$(prompt_yn CODEX_INTEGRATION_ENABLED 'Wire skills into ~/.codex/skills/ as well as ~/.claude/skills/?' "$(command -v codex >/dev/null && echo y || echo n)")"

# Local Postgres — qspinuplocal / qe2etest / qmigrationdevcheck render these.
# Honour any --config value; fall back to quiet defaults so placeholders fill.
LOCAL_DB_USER="$(prompt_or_default LOCAL_DB_USER 'Local Postgres role' "$USER")"
LOCAL_DB_HOST="$(prompt_or_default LOCAL_DB_HOST 'Local Postgres host' 'localhost')"
LOCAL_DB_PORT="$(prompt_or_default LOCAL_DB_PORT 'Local Postgres port' '5432')"
LOCAL_DEV_DB_NAME="$(prompt_or_default LOCAL_DEV_DB_NAME 'Default local dev DB name' 'dev_db')"
DB_OWNER_ROLE="$(prompt_or_default DB_OWNER_ROLE 'DB owner role (Postgres)' 'app_admin')"

STATE_ROOT="$(prompt_or_default STATE_ROOT 'Where qship stores transient state' "/tmp/${COMPANY_SLUG_LOWER}-qship")"
EXAMPLE_TICKET_ID="$(prompt_or_default EXAMPLE_TICKET_ID 'Example ticket ID to use in docs' "$JIRA_PROJECT_KEY-1")"

# Optional integrations (opt-in)
# Atlassian cloudId only matters for the Jira tracker; skip the prompt otherwise.
if [[ "$TRACKER_TYPE" == "jira" ]]; then
  ATLASSIAN_CLOUD_ID="$(prompt_or_default ATLASSIAN_CLOUD_ID 'Atlassian cloudId (find via mcp__atlassian__getAccessibleAtlassianResources — blank to skip)' '')"
else
  ATLASSIAN_CLOUD_ID="${ATLASSIAN_CLOUD_ID:-}"
fi
# ngrok reserved domain — qe2etest can expose the local stack via a public URL.
NGROK_RESERVED_DOMAIN="$(prompt_or_default NGROK_RESERVED_DOMAIN 'ngrok reserved domain (blank if not used)' '')"
NGROK_RESERVED_DOMAIN="${NGROK_RESERVED_DOMAIN:-}"
USER_EMAIL_OR_BLANK="$(prompt_or_default USER_EMAIL_OR_BLANK 'Your email for commit-attribution rules (blank to skip)' '')"
USER_NAME_OR_BLANK="$(prompt_or_default USER_NAME_OR_BLANK 'Your name for narrative (blank to skip)' '')"

# Env-var key names for integrations (questionnaire keeps these short)
ENV_SERVICE_URL_KEY="$(prompt_or_default ENV_SERVICE_URL_KEY 'Env var name for your service base URL' 'SERVICE_URL')"
ENV_CLOUD_URL_KEY="$(prompt_or_default ENV_CLOUD_URL_KEY 'Env var name for "cloud / SaaS base URL"' 'CLOUD_URL')"
ENV_OAUTH_CLIENT_ID_KEY="$(prompt_or_default ENV_OAUTH_CLIENT_ID_KEY 'Env var name for OAuth client id' 'OAUTH_CLIENT_ID')"
ENV_OAUTH_CLIENT_SECRET_KEY="$(prompt_or_default ENV_OAUTH_CLIENT_SECRET_KEY 'Env var name for OAuth client secret' 'OAUTH_CLIENT_SECRET')"

# Export everything so envsubst can see it
export USER_HOME SKILLS_ROOT CODEBASE_ROOT CODEBASE_DIR_NAME COMPANY_SLUG COMPANY_SLUG_LOWER COMPANY_SLUG_UPPER CODEBASE_PATH_PREFIX COMPANY_DOMAIN
export TRACKER_TYPE JIRA_PROJECT_KEY GH_HOST GH_ORG DEFAULT_BRANCH
export REPOS_JSON REPO_COUNT PRIMARY_REPO_NAME
export PRIMARY_LANGUAGE TEST_COMMAND LINT_COMMAND FORMAT_COMMAND
export LOCAL_DB_USER LOCAL_DB_HOST LOCAL_DB_PORT LOCAL_DEV_DB_NAME DB_OWNER_ROLE
export STATE_ROOT EXAMPLE_TICKET_ID
export ATLASSIAN_CLOUD_ID NGROK_RESERVED_DOMAIN USER_EMAIL_OR_BLANK USER_NAME_OR_BLANK
export ENV_SERVICE_URL_KEY ENV_CLOUD_URL_KEY ENV_OAUTH_CLIENT_ID_KEY ENV_OAUTH_CLIENT_SECRET_KEY
export CODEX_INTEGRATION_ENABLED

# Save final answers as JSON for re-runs (matches config.example.json schema).
# Boolean fields are emitted as true/false, integers as numbers — `jq` enforces
# the typing.  String fields get JSON-escaped via jq's @json filter.
ANSWERS_FILE="$REPO_ROOT/answers/last-run.json"
mkdir -p "$(dirname "$ANSWERS_FILE")"

bool_json() { case "${1:-n}" in y|yes|Y|YES|true) echo "true" ;; *) echo "false" ;; esac; }

cat > "$ANSWERS_FILE" <<JSON
{
  "_generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "_generated_by": "setup.sh",
  "identity": {
    "company_slug": $(jq -Rn --arg v "$COMPANY_SLUG" '$v'),
    "company_slug_lower": $(jq -Rn --arg v "$COMPANY_SLUG_LOWER" '$v'),
    "company_slug_upper": $(jq -Rn --arg v "$COMPANY_SLUG_UPPER" '$v'),
    "company_domain": $(jq -Rn --arg v "$COMPANY_DOMAIN" '$v'),
    "user_name_or_blank": $(jq -Rn --arg v "$USER_NAME_OR_BLANK" '$v'),
    "user_email_or_blank": $(jq -Rn --arg v "$USER_EMAIL_OR_BLANK" '$v')
  },
  "codebase": {
    "user_home": $(jq -Rn --arg v "$USER_HOME" '$v'),
    "skills_root": $(jq -Rn --arg v "$SKILLS_ROOT" '$v'),
    "codebase_root": $(jq -Rn --arg v "$CODEBASE_ROOT" '$v'),
    "codebase_dir_name": $(jq -Rn --arg v "$CODEBASE_DIR_NAME" '$v'),
    "codebase_path_prefix": $(jq -Rn --arg v "$CODEBASE_PATH_PREFIX" '$v'),
    "default_branch": $(jq -Rn --arg v "$DEFAULT_BRANCH" '$v')
  },
  "repos": $REPOS_JSON,
  "tooling": {
    "primary_language": $(jq -Rn --arg v "$PRIMARY_LANGUAGE" '$v'),
    "test_command": $(jq -Rn --arg v "$TEST_COMMAND" '$v'),
    "lint_command": $(jq -Rn --arg v "$LINT_COMMAND" '$v'),
    "format_command": $(jq -Rn --arg v "$FORMAT_COMMAND" '$v')
  },
  "local_db": {
    "local_db_user": $(jq -Rn --arg v "$LOCAL_DB_USER" '$v'),
    "local_db_host": $(jq -Rn --arg v "$LOCAL_DB_HOST" '$v'),
    "local_db_port": $LOCAL_DB_PORT,
    "local_dev_db_name": $(jq -Rn --arg v "$LOCAL_DEV_DB_NAME" '$v'),
    "db_owner_role": $(jq -Rn --arg v "$DB_OWNER_ROLE" '$v')
  },
  "tracker": {
    "tracker_type": $(jq -Rn --arg v "$TRACKER_TYPE" '$v'),
    "jira_project_key": $(jq -Rn --arg v "$JIRA_PROJECT_KEY" '$v'),
    "example_ticket_id": $(jq -Rn --arg v "$EXAMPLE_TICKET_ID" '$v'),
    "atlassian_cloud_id": $(jq -Rn --arg v "$ATLASSIAN_CLOUD_ID" '$v')
  },
  "github": {
    "gh_host": $(jq -Rn --arg v "$GH_HOST" '$v'),
    "gh_org": $(jq -Rn --arg v "$GH_ORG" '$v')
  },
  "env_var_names": {
    "env_service_url_key": $(jq -Rn --arg v "$ENV_SERVICE_URL_KEY" '$v'),
    "env_cloud_url_key": $(jq -Rn --arg v "$ENV_CLOUD_URL_KEY" '$v'),
    "env_oauth_client_id_key": $(jq -Rn --arg v "$ENV_OAUTH_CLIENT_ID_KEY" '$v'),
    "env_oauth_client_secret_key": $(jq -Rn --arg v "$ENV_OAUTH_CLIENT_SECRET_KEY" '$v')
  },
  "state": {
    "state_root": $(jq -Rn --arg v "$STATE_ROOT" '$v'),
    "ngrok_reserved_domain": $(jq -Rn --arg v "$NGROK_RESERVED_DOMAIN" '$v')
  },
  "features": {
    "codex_integration_enabled": $(bool_json "$CODEX_INTEGRATION_ENABLED")
  }
}
JSON

ok "Saved answers to $ANSWERS_FILE — re-run non-interactively with: bash setup.sh --config $ANSWERS_FILE"

# ---------------------------------------------------------------------------
# 3. External plugin-skill dependency check (detect-and-instruct)
# ---------------------------------------------------------------------------
log
log "==> Checking external plugin marketplace dependencies"
PLUGINS_FILE="$DEPS_ROOT/plugin-marketplaces.txt"
MISSING_PLUGINS="$(missing_external_plugins || true)"
if [[ -z "$MISSING_PLUGINS" ]]; then
  ok "All required external plugins already installed"
else
  warn "Required plugins are MISSING. qship skills that delegate to them will FAIL"
  warn "mid-pipeline (e.g. Step 8.1 superpowers:code-reviewer) until you install these."
  log  "Open Claude Code and paste:"
  log
  while IFS=$'\t' read -r marketplace install_cmd description; do
    [[ -z "${marketplace:-}" ]] && continue
    log "  • $description"
    log "      /plugin marketplace add $marketplace"
    log "      /plugin install $install_cmd"
    log
  done <<< "$MISSING_PLUGINS"
  if ! $NONINTERACTIVE; then
    read -r -p "Press Enter once you've installed (or noted) the required plugins, or Ctrl-C to abort: " _ </dev/tty
  fi
fi

# ---------------------------------------------------------------------------
# 4. Render templates
# ---------------------------------------------------------------------------
SKILL_INSTALL_LIST=()
SKILL_OPT_LIST=()

# ---------------------------------------------------------------------------
# Install the full qship pipeline (21 skills). Every one is reachable from the
# qship / qshipmaster pipeline (directly or transitively), so there is nothing
# to toggle — installing fewer would break the pipeline at runtime.
# ---------------------------------------------------------------------------
SKILL_INSTALL_LIST+=(qship qshipmaster qshipcheck qshipphasecheck)
SKILL_INSTALL_LIST+=(qplan qdirectory qclean qreuse qcheck qcheckt qcheckf qcomponent qbug qbcheck)
SKILL_INSTALL_LIST+=(qmemory qe2etest qmanualt qspinuplocal qlocalclonedb qmigrationdevcheck qauthtrailingslash)


log
log "==> Installing ${#SKILL_INSTALL_LIST[@]} skill(s) to $SKILLS_ROOT"

# Write the rendered repos.json to the qship skill directory so runtime skills
# can `jq` it without re-reading the (potentially-moved) config.json.
# Skills should: REPOS="$(jq -c . "$SKILLS_ROOT/qship/repos.json")" then iterate.
mkdir -p "$SKILLS_ROOT/qship"
if $DRY_RUN; then
  log "  [dry-run] would write repos.json to $SKILLS_ROOT/qship/repos.json"
else
  printf '%s\n' "$REPOS_JSON" | jq . > "$SKILLS_ROOT/qship/repos.json"
fi

# envsubst against an allowlist so we don't accidentally expand $LD_LIBRARY_PATH etc.
ALLOWED_VARS='$USER_HOME $SKILLS_ROOT $CODEBASE_ROOT $CODEBASE_DIR_NAME $COMPANY_SLUG $COMPANY_SLUG_LOWER $COMPANY_SLUG_UPPER $CODEBASE_PATH_PREFIX $COMPANY_DOMAIN '\
'$TRACKER_TYPE $JIRA_PROJECT_KEY $GH_HOST $GH_ORG $DEFAULT_BRANCH '\
'$PRIMARY_REPO_NAME $REPO_COUNT '\
'$PRIMARY_LANGUAGE $TEST_COMMAND $LINT_COMMAND $FORMAT_COMMAND '\
'$LOCAL_DB_USER $LOCAL_DB_HOST $LOCAL_DB_PORT $LOCAL_DEV_DB_NAME $DB_OWNER_ROLE '\
'$STATE_ROOT $EXAMPLE_TICKET_ID '\
'$ATLASSIAN_CLOUD_ID $NGROK_RESERVED_DOMAIN $USER_EMAIL_OR_BLANK $USER_NAME_OR_BLANK '\
'$ENV_SERVICE_URL_KEY $ENV_CLOUD_URL_KEY $ENV_OAUTH_CLIENT_ID_KEY $ENV_OAUTH_CLIENT_SECRET_KEY'

render_one() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  if $DRY_RUN; then
    log "  [dry-run] would render: $src -> $dst"
    return
  fi
  # Two-pass substitution:
  #   1. sed converts Jinja-style {{VAR}} → shell-style ${VAR} so envsubst
  #      can handle them.  We DELIBERATELY use {{VAR}} as the placeholder
  #      syntax in templates because bare $VAR would conflict with the
  #      many real bash variables embedded in shell scripts (e.g. $EPIC_ID
  #      inside a bash heredoc — that's a runtime var, NOT a config knob).
  #   2. envsubst substitutes ${VAR} against the allowlist.  Anything not
  #      in ALLOWED_VARS is left intact, so runtime bash vars survive.
  sed -E 's/\{\{([A-Z][A-Z0-9_]*)\}\}/\${\1}/g' "$src" \
    | envsubst "$ALLOWED_VARS" > "$dst"
  # Preserve executable bit for .sh files (heuristic: source had x-bit, or
  # filename matches *.sh).
  if [[ -x "$src" || "$src" == *.sh ]]; then
    chmod +x "$dst"
  fi
}

INSTALLED=()
SKIPPED=()
for skill in "${SKILL_INSTALL_LIST[@]}"; do
  src_dir="$TEMPLATES_ROOT/skills/$skill"
  if [[ ! -d "$src_dir" ]]; then
    SKIPPED+=("$skill (template missing — reinstall qship)")
    continue
  fi
  dst_dir="$SKILLS_ROOT/$skill"
  # Every file under the templated skill dir gets rendered.  envsubst is a
  # no-op on files without $VAR tokens, so non-templated assets pass through
  # unchanged.
  find "$src_dir" -type f | while read -r src; do
    rel="${src#$src_dir/}"
    render_one "$src" "$dst_dir/$rel"
  done
  INSTALLED+=("$skill")
done

# Agents
if [[ -f "$TEMPLATES_ROOT/agents/qship-worker.md" ]]; then
  render_one "$TEMPLATES_ROOT/agents/qship-worker.md" "$CLAUDE_DIR/agents/qship-worker.md"
fi

ok "Installed: ${INSTALLED[*]:-(none)}"
[[ ${#SKIPPED[@]} -gt 0 ]] && warn "Skipped: ${SKIPPED[*]}"

# ---------------------------------------------------------------------------
# 5. Hook registration in settings.json
# ---------------------------------------------------------------------------
log
log "==> Registering hooks in $CLAUDE_DIR/settings.json"
HOOK_SNIPPET="$TEMPLATES_ROOT/hooks-settings/qship-hooks.json"
if [[ -f "$HOOK_SNIPPET" ]]; then
  rendered="$(sed -E 's/\{\{([A-Z][A-Z0-9_]*)\}\}/\${\1}/g' "$HOOK_SNIPPET" | envsubst "$ALLOWED_VARS")"
  settings="$CLAUDE_DIR/settings.json"
  if $DRY_RUN; then
    log "  [dry-run] would jq-merge:"
    echo "$rendered" | head -20
  else
    [[ -f "$settings" ]] || echo '{"hooks":{}}' > "$settings"
    cp "$settings" "${settings}.bak.$(date +%s)"
    tmp="$(mktemp)"
    # Merge: rendered.hooks deep-merges into settings.hooks (rendered wins on conflict).
    jq -s '.[0] * .[1]' "$settings" <(echo "$rendered") > "$tmp" && mv "$tmp" "$settings"
    ok "Hooks merged into $settings (backup at ${settings}.bak.*)"
  fi
else
  warn "Hook snippet missing — skipping settings.json merge"
fi

# ---------------------------------------------------------------------------
# 6. Codex symlinks (optional)
# ---------------------------------------------------------------------------
if [[ "$CODEX_INTEGRATION_ENABLED" == "y" && -d "$HOME/.codex" ]]; then
  log
  log "==> Linking skills into ~/.codex/skills/"
  mkdir -p "$HOME/.codex/skills"
  for skill in "${INSTALLED[@]}"; do
    target="$SKILLS_ROOT/$skill"
    link="$HOME/.codex/skills/$skill"
    if $DRY_RUN; then
      log "  [dry-run] would symlink: $link -> $target"
    else
      ln -sfn "$target" "$link"
    fi
  done
  ok "Codex symlinks updated"
fi

# ---------------------------------------------------------------------------
# 6.5 Touch the first-run marker — silences the SessionStart hook on next launch.
# ---------------------------------------------------------------------------
# Lives under SKILLS_ROOT so it matches where the SessionStart hook looks
# (the hook checks "$SKILLS_ROOT/qship/.configured").
MARKER="$SKILLS_ROOT/qship/.configured"
if ! $DRY_RUN; then
    mkdir -p "$(dirname "$MARKER")"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER"
    ok "First-run marker written to $MARKER"
fi

# ---------------------------------------------------------------------------
# 7. Quickstart
# ---------------------------------------------------------------------------
log
log "=============================================================================="
log " ✅ qship installed"
log "=============================================================================="
log
log "Try it:"
log "  /qship $EXAMPLE_TICKET_ID                                    # default Claude impl + Claude review"
log "  /qship $EXAMPLE_TICKET_ID provider=codex                     # Codex implements"
log "  /qship $EXAMPLE_TICKET_ID reviewer=codex                     # Claude implements, Codex reviews"
log "  /qshipmaster $JIRA_PROJECT_KEY-100 provider=claude reviewer=codex"
log
log "Verify the install at any time:"
log "  bash $REPO_ROOT/setup.sh --check"
log
if [[ -n "${MISSING_PLUGINS:-}" ]]; then
  warn "Before your first /qship run, install the MISSING external plugins listed above —"
  warn "skills that delegate to them fail mid-pipeline otherwise. Re-check with: setup.sh --check"
  log
fi
log "Docs: $REPO_ROOT/docs/"
log "Customize: $REPO_ROOT/docs/CUSTOMIZING.md"
log
log "Re-run installer (e.g. after editing answers/last-run.json):"
log "  bash $REPO_ROOT/setup.sh --config $REPO_ROOT/answers/last-run.json"
log "Or edit $REPO_ROOT/config.json (copied from config.example.json) and re-run setup.sh."
log
log "Uninstall: bash $REPO_ROOT/uninstall.sh"
