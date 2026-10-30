#!/bin/bash
# iOS Simulator Unit Tests for AnchorWatch
# Runs ~240+ Swift unit tests in iPhone simulator (no code signing required)

set -e

echo "=== Running iOS Unit Tests ==="
xcodebuild test \
  -scheme AnchorWatch \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

echo ""
echo "✅ iOS tests completed successfully"
