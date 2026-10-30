#!/bin/bash
# Shared Kotlin JVM Unit Tests for AnchorWatch
# Runs commonTest and jvmTest source sets via Android Gradle wrapper

set -e

echo "=== Running Shared Kotlin JVM Tests ==="
cd android
./gradlew :shared:jvmTest --console=plain

echo ""
echo "✅ Shared Kotlin tests completed successfully"
