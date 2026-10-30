#!/bin/bash
# Run All Automated Tests for AnchorWatch
# Executes iOS, Shared Kotlin, and Android unit tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "AnchorWatch Full Test Suite"
echo "=========================================="
echo ""

# Track which tests run
TESTS_RUN=()
TESTS_FAILED=()

# 1. iOS Tests
echo "[1/3] Running iOS Unit Tests..."
if "$SCRIPT_DIR/test-ios.sh"; then
    TESTS_RUN+=("iOS")
else
    TESTS_FAILED+=("iOS")
fi
echo ""

# 2. Shared Kotlin Tests
echo "[2/3] Running Shared Kotlin JVM Tests..."
cd "$PROJECT_ROOT"
if "$SCRIPT_DIR/test-shared.sh"; then
    TESTS_RUN+=("Shared Kotlin")
else
    TESTS_FAILED+=("Shared Kotlin")
fi
echo ""

# 3. Android Tests
echo "[3/3] Running Android Unit Tests..."
cd "$PROJECT_ROOT"
if "$SCRIPT_DIR/test-android.sh"; then
    TESTS_RUN+=("Android")
else
    TESTS_FAILED+=("Android")
fi
echo ""

# Summary
echo "=========================================="
echo "Test Suite Summary"
echo "=========================================="
echo "Tests run: ${TESTS_RUN[*]}"
if [ ${#TESTS_FAILED[@]} -gt 0 ]; then
    echo "Tests failed: ${TESTS_FAILED[*]}"
    exit 1
else
    echo "✅ All tests passed!"
fi
