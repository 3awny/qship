#!/bin/bash
# qshipmaster-tcc-preflight.sh
#
# Pre-flight check before qshipmaster spawns any claude --print subprocess that
# uses Playwright / Chrome / browser MCPs. Detects the macOS TCC permission
# stall pattern (subprocess blocks waiting for a popup that fires elsewhere
# and is never answered) FAST — instead of letting it eat 30+ min of stream-
# json hang time.
#
# Pattern: try a minimal Playwright/Chrome operation with a 30s timeout. If
# it succeeds, permissions are good. If it times out OR returns a
# permission-denied error, fail-fast with a clear message telling the user
# which TCC permission to grant.
#
# Returns:
#   0 — all good, proceed
#   1 — permissions failing, with stderr message
#   2 — environmental error (Playwright not installed, Chrome not at :9222),
#       caller should treat as warn-not-fail

set -eo pipefail

CHROME_DEBUG_PORT="${CHROME_DEBUG_PORT:-9222}"
PREFLIGHT_TIMEOUT="${QSHIP_TCC_PREFLIGHT_TIMEOUT:-30}"
SKIP="${QSHIP_SKIP_TCC_PREFLIGHT:-false}"

if [ "$SKIP" = "true" ]; then
  exit 0
fi

# Check 1: chrome-devtools-attach path — is Chrome at :9222 responsive?
# This is the PREFERRED path (inherits user's stable Chrome permissions).
chrome_ok=false
if curl -sf --max-time 2 "http://127.0.0.1:${CHROME_DEBUG_PORT}/json/version" >/dev/null 2>&1; then
  chrome_ok=true
fi

# Check 2: Playwright path — fresh Chromium subprocess.
# This is the FALLBACK and the one that's permission-prone.
# Spawn Playwright with a 30s timeout, just navigate to about:blank.
# If macOS needs Accessibility/Screen-Recording, the subprocess hangs.
playwright_ok=false
playwright_test_output=$(mktemp -t qship-tcc-preflight.XXXXXX)

if command -v npx >/dev/null 2>&1; then
  # Use a here-doc node script for the minimal Playwright test.
  timeout "$PREFLIGHT_TIMEOUT" npx --yes -p playwright-core node -e '
    const { chromium } = require("playwright-core");
    (async () => {
      const browser = await chromium.launch({ headless: true, timeout: 20000 });
      const page = await browser.newPage();
      await page.goto("about:blank", { timeout: 10000 });
      await browser.close();
      console.log("PLAYWRIGHT_OK");
    })().catch(e => { console.error("PLAYWRIGHT_FAIL:", e.message); process.exit(1); });
  ' > "$playwright_test_output" 2>&1 && playwright_ok=true || true
fi

# Decide outcome.
if $chrome_ok; then
  echo "[tcc-preflight] OK — chrome-devtools-attach available at port ${CHROME_DEBUG_PORT}, no TCC dependency for Phase 3" >&2
  rm -f "$playwright_test_output"
  exit 0
fi

if $playwright_ok; then
  echo "[tcc-preflight] OK — Playwright fresh Chromium spawns within ${PREFLIGHT_TIMEOUT}s, no TCC stall detected" >&2
  rm -f "$playwright_test_output"
  exit 0
fi

# Both failed — diagnose.
output=$(cat "$playwright_test_output" 2>/dev/null || true)
rm -f "$playwright_test_output"

cat >&2 <<EOF
[tcc-preflight] FAIL — Playwright fresh-Chromium spawn exceeded ${PREFLIGHT_TIMEOUT}s timeout.

This is the silent-stall signature documented in qshipmaster AGENTS.md:
  - macOS subprocess (Playwright/Chromium) blocks on a TCC popup
  - Popup fires in the host terminal app's permission dialog, not the subprocess
  - If user isn't watching, popup goes unanswered → subprocess hangs forever
  - qshipmaster Phase 3 then frozen for 30+ min before supervisor SIGTERMs

LIKELY CAUSE: one of these permissions is needed but not granted for the host:
  /Applications/Claude.app (or the Terminal app hosting this CLI):

  - Privacy & Security → Accessibility            (Playwright keyboard/mouse)
  - Privacy & Security → Screen Recording          (screenshots)
  - Privacy & Security → Automation → Chrome       (chrome-devtools-attach)
  - Privacy & Security → Full Disk Access          (reduces other prompts)

FIX:
  1. Open System Settings → Privacy & Security
  2. For each permission above, click "+" and add /Applications/Claude.app
  3. If Claude.app appears as "denied" already, remove it and re-add
  4. Alternatively reset cached denials:
        sudo tccutil reset Accessibility com.anthropic.claudefordesktop
        sudo tccutil reset ScreenCapture com.anthropic.claudefordesktop
        sudo tccutil reset SystemPolicyAllFiles com.anthropic.claudefordesktop
        sudo tccutil reset AppleEvents com.anthropic.claudefordesktop
  5. Re-run qshipmaster — answer ANY popup that appears with "Allow"

ALTERNATIVELY: ensure chrome-devtools-attach is up at port ${CHROME_DEBUG_PORT}
(qshipmaster-run.sh auto-launches it; if launch is disabled via
QSHIP_SKIP_CHROME=true, re-enable it). chrome-devtools-attach inherits the
user's interactive Chrome's stable permissions and bypasses TCC entirely.

Last Playwright stderr (first 500 chars):
${output:0:500}
EOF

exit 1
