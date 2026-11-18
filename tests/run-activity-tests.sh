#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p verification
swiftc -swift-version 5 -parse-as-library \
  ios/Shared/TunnelActivityState.swift ios/FrpClient/ConnectionActivityController.swift \
  tests/ActivityTests.swift -o verification/activity-tests
verification/activity-tests
