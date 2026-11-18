#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
chat_test_bin="$(mktemp /private/tmp/frpclient-chat-tests.XXXXXX)"
trap 'rm -f "$chat_test_bin"' EXIT
swiftc -swift-version 5 \
  ios/FrpClient/ChatTransport.swift \
  ios/FrpClient/ChatHistoryStore.swift \
  ios/FrpClient/ChatController.swift \
  tests/ChatTestSupport.swift tests/ChatTests.swift \
  -o "$chat_test_bin"
"$chat_test_bin"
