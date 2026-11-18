#!/usr/bin/env bash
# Requires a separately booted disposable simulator ID. Never uses an existing
# user's app container, Keychain, or live server. Builds a loopback-only fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${FRP_UI_SIMULATOR_ID:?Set this to a disposable simulator UUID}"
mkdir -p build/ui-fixture build/e2e-tools verification
ui_fixture_dir="$(mktemp -d "$PWD/build/ui-fixture-run.XXXXXX")"
export GOPROXY=off GOTOOLCHAIN=local
go -C go build -tags noweb -o "$PWD/build/e2e-tools/frps" github.com/fatedier/frp/cmd/frps
CHAT_UI_FIXTURE_DIR="$ui_fixture_dir" FRPS_BIN="$PWD/build/e2e-tools/frps" \
  go -C go run ./e2e > verification/simulator-fixture.log 2>&1 &
fixture_job=$!
trap 'touch "$ui_fixture_dir/stop"; wait "$fixture_job" || true' EXIT
for ((attempt=0; attempt<100; attempt++)); do
  [[ -f "$ui_fixture_dir/fixture.json" ]] && break
  kill -0 "$fixture_job" 2>/dev/null || { cat verification/simulator-fixture.log; exit 1; }
  sleep 0.1
done
[[ -f "$ui_fixture_dir/fixture.json" ]]
cp "$ui_fixture_dir/fixture.json" build/ui-fixture/fixture.json
ui_result="verification/ui-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project ios/FrpClient.xcodeproj -scheme FrpChatAcceptance \
  -configuration Debug -destination "platform=iOS Simulator,id=$FRP_UI_SIMULATOR_ID" \
  -derivedDataPath build/UITestData -resultBundlePath "$ui_result" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 660 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
