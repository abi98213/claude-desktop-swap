#!/bin/bash
# Renders the README screenshots from a made-up demo setup (three fake
# accounts, fake usage). Never reads your real Claude data.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product ClaudeSwapApp --product cdswap >/dev/null
DEMO="$(mktemp -d)"
trap 'rm -rf "$DEMO"' EXIT
python3 - "$DEMO" <<'PY'
import sys
sys.path.insert(0, "tests")
import test_cli as t
f = t.Fake(sys.argv[1])
f.sign_in(t.A); f.usage_sample(t.ORG1, fh=100, sd=62, minutes_ago=90); f.run("add", "maya@studio.com")
f.run("new"); f.sign_in(t.B); f.usage_sample(t.ORG2, fh=34, sd=18, minutes_ago=3); f.run("add", "maya@gmail.com")
C = "cccccccc-0000-0000-0000-000000000003"
f.run("new"); f.sign_in(C); f.usage_sample(t.ORG2, fh=8, sd=71); f.run("add", "maya@agency.io")
f.run("switch", "maya@gmail.com"); f.run("config", "autoSwitch", "true")
PY
export CDSWAP_CLAUDE_DIR="$DEMO/Claude" CDSWAP_HOME="$DEMO/store" CDSWAP_NO_APP=1
APP=.build/debug/ClaudeSwapApp
mkdir -p docs
"$APP" --render-preview docs/menu-light.png
"$APP" --render-preview docs/menu-dark.png --dark
"$APP" --render-preview docs/countdown.png --countdown --dark
echo "Rendered docs/menu-light.png docs/menu-dark.png docs/countdown.png"
