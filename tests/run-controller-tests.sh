#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p verification
swiftc -swift-version 5 -D FRPCLIENT_TESTS \
  ios/Shared/TunnelActivityState.swift ios/FrpClient/FrpcController.swift ios/FrpClient/ChatController.swift \
  ios/FrpClient/ChatTransport.swift ios/FrpClient/ChatHistoryStore.swift \
  tests/ControllerSupport.swift tests/ControllerTests.swift \
  -o verification/controller-tests
verification/controller-tests
