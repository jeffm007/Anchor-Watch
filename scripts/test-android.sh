#!/bin/bash
# Android Unit Tests for AnchorWatch
# Runs JUnit tests including CSV fixture parity checks

set -e

echo "=== Running Android Unit Tests ==="
cd android
./gradlew testDebugUnitTest --console=plain

echo "✅ Android tests completed successfully"
