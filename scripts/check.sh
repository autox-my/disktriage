#!/usr/bin/env bash
# DiskDoctor gate — three outcomes, and the third is never a pass:
#
#   0  PASS
#   1  FAIL            (yours to fix)
#   3  UNVERIFIABLE    (could not run / could not decide — stop and report)
#
# Exit statuses are captured explicitly and never read through a pipeline.
# A runner that exits 0 without executing a test is UNVERIFIABLE, not PASS.
#
# Build system: this machine's toolchain cannot initialise the default
# `swiftbuild` engine ("Unknown error parsing property list", CLT-only
# install), so the gate pins `native`. Override with DISKDOCTOR_BUILD_SYSTEM
# only if you are testing that change deliberately.
#
# Test runner: `/usr/bin/swift` from the Command Line Tools ships without
# XCTest and without Swift Testing, so `swift test` cannot execute a suite
# here. The suite is a dependency-free executable (Tests/DiskDoctorCoreTests)
# and `swift test` replaces it the day the toolchain provides a framework.
# See docs/sdlc.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
    echo "UNVERIFIABLE  cannot resolve the repository root"
    exit 3
}
cd "$ROOT" || {
    echo "UNVERIFIABLE  cannot enter $ROOT"
    exit 3
}

SWIFT_BIN="${SWIFT_BIN:-$(command -v swift 2>/dev/null || true)}"
if [ -z "$SWIFT_BIN" ] || [ ! -x "$SWIFT_BIN" ]; then
    echo "SKIP          swift not found (set SWIFT_BIN)"
    echo "UNVERIFIABLE"
    exit 3
fi

BUILD_SYSTEM="${DISKDOCTOR_BUILD_SYSTEM:-native}"
LOG_DIR="$(mktemp -d)" || {
    echo "UNVERIFIABLE  cannot create a temporary directory"
    exit 3
}
trap 'rm -rf "$LOG_DIR"' EXIT
BUILD_LOG="$LOG_DIR/build.log"
TEST_LOG="$LOG_DIR/test.log"

run_build() {
    echo "== build =="
    "$SWIFT_BIN" build --build-system "$BUILD_SYSTEM" >"$BUILD_LOG" 2>&1
    local rc=$?
    cat "$BUILD_LOG"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL          swift build exited $rc"
        return 1
    fi
    echo "PASS          swift build"
}

run_tests() {
    echo "== test =="
    "$SWIFT_BIN" run --build-system "$BUILD_SYSTEM" DiskDoctorCoreTests >"$TEST_LOG" 2>&1
    local rc=$?
    cat "$TEST_LOG"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL          test runner exited $rc"
        return 1
    fi

    # The runner's own summary is the only evidence that tests ran.
    local summary
    summary="$(awk '/^Executed [0-9]+ tests, [0-9]+ failures$/{ last = $0 } END{ print last }' "$TEST_LOG")"
    if [ -z "$summary" ]; then
        echo "UNVERIFIABLE  runner exited 0 but printed no 'Executed N tests, M failures' summary"
        return 3
    fi

    local total failures
    total="${summary#Executed }"
    total="${total%% tests,*}"
    failures="${summary##*tests, }"
    failures="${failures%% *}"

    if [ "$total" -le 0 ]; then
        echo "UNVERIFIABLE  runner executed $total tests"
        return 3
    fi
    if [ "$failures" -ne 0 ]; then
        echo "FAIL          $failures of $total tests failed"
        return 1
    fi
    echo "PASS          $total tests, 0 failures"
}

run_build
build_rc=$?
if [ "$build_rc" -ne 0 ]; then
    echo "FAIL"
    exit 1
fi

run_tests
test_rc=$?
case "$test_rc" in
    0) echo "PASS"; exit 0 ;;
    3) echo "UNVERIFIABLE"; exit 3 ;;
    *) echo "FAIL"; exit 1 ;;
esac
