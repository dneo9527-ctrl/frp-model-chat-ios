#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
update_test_bin="$(mktemp /private/tmp/frpmodelchat-update-tests.XXXXXX)"
trap 'rm -f "$update_test_bin"' EXIT
swiftc -swift-version 5 \
  ios/FrpClient/ChatTransport.swift ios/FrpClient/ChatHistoryStore.swift \
  ios/FrpClient/ChatController.swift ios/FrpClient/AppUpdates.swift \
  tests/ChatTestSupport.swift tests/UpdateTests.swift -o "$update_test_bin"
"$update_test_bin"
