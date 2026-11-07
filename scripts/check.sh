#!/usr/bin/env bash
# disktriage gate — three outcomes, and the third is never a pass:
#
#   0  PASS
#   1  FAIL            (yours to fix)
#   3  UNVERIFIABLE    (could not run / could not decide — stop and report)
#
# Exit statuses are captured explicitly and never read through a pipeline.
# A runner that exits 0 without executing a test is UNVERIFIABLE, not PASS,
# and so is a missing, empty or unparsable JUnit report: the report is the
# evidence that the tests ran at all.
#
# The gate builds, runs the Swift Testing suite through `swift test` with a
# JUnit report, and counts the report. SwiftPM writes swift-testing results to
# `<stem>-swift-testing.xml` beside the requested `<stem>.xml`, so both are
# collected; XCTest, if it is ever added, lands in the requested file.
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

XMLLINT_BIN="${XMLLINT_BIN:-$(command -v xmllint 2>/dev/null || true)}"
if [ -z "$XMLLINT_BIN" ] || [ ! -x "$XMLLINT_BIN" ]; then
    echo "SKIP          xmllint not found (set XMLLINT_BIN); the report cannot be counted"
    echo "UNVERIFIABLE"
    exit 3
fi

LOG_DIR="$(mktemp -d)" || {
    echo "UNVERIFIABLE  cannot create a temporary directory"
    exit 3
}
trap 'rm -rf "$LOG_DIR"' EXIT
BUILD_LOG="$LOG_DIR/build.log"
TEST_LOG="$LOG_DIR/test.log"

# Gitignored by `.build/`. No stale report may answer for this run: the test
# step removes both files before invoking the runner.
REPORT_DIR="$ROOT/.build/test-results"
REPORT_STEM="$REPORT_DIR/junit"
REQUESTED_REPORT="$REPORT_STEM.xml"
SWIFT_TESTING_REPORT="$REPORT_STEM-swift-testing.xml"

run_build() {
    echo "== build =="
    "$SWIFT_BIN" build >"$BUILD_LOG" 2>&1
    local rc=$?
    cat "$BUILD_LOG"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL          swift build exited $rc"
        return 1
    fi
    echo "PASS          swift build"
}

# Counts and decides a JUnit report. Shared with scripts/check-gate-probe.sh,
# which proves the pass/fail/skip rule bites without running the suite.
. "$ROOT/scripts/lib/junit-report.sh"

# Lists the `disktriage-*` directories under the temp roots before and after the
# suite. Shared with scripts/check-gate-probe.sh, which proves the leak rule
# bites without touching a real leftover.
. "$ROOT/scripts/lib/temp-leak.sh"
TEMP_BEFORE="$LOG_DIR/temp-before.txt"
TEMP_AFTER="$LOG_DIR/temp-after.txt"

run_tests() {
    echo "== test =="
    mkdir -p "$REPORT_DIR" || {
        echo "UNVERIFIABLE  cannot create $REPORT_DIR"
        return 3
    }
    rm -f "$REQUESTED_REPORT" "$SWIFT_TESTING_REPORT"

    # The temp directory's `disktriage-*` directories are the suite's property.
    # Snapshot before the runner starts; pre-existing ones are a warning only.
    temp_leak_snapshot >"$TEMP_BEFORE"

    "$SWIFT_BIN" test --xunit-output "$REQUESTED_REPORT" >"$TEST_LOG" 2>&1
    local rc=$?
    cat "$TEST_LOG"

    temp_leak_snapshot >"$TEMP_AFTER"

    local leak_output leak_rc
    leak_output="$(temp_leak_verdict "$TEMP_BEFORE" "$TEMP_AFTER")"
    leak_rc=$?
    echo "$leak_output"

    local report total=0 failed=0 skipped=0 seen=0 counts written=""
    local report_total report_failed report_skipped
    for report in "$REQUESTED_REPORT" "$SWIFT_TESTING_REPORT"; do
        if [ ! -s "$report" ]; then
            continue
        fi
        counts="$(count_report "$report")"
        case "$?" in
            0) ;;
            *) echo "$counts"; [ "$leak_rc" -ne 0 ] && return 1; return 3 ;;
        esac
        seen=$((seen + 1))
        read -r report_total report_failed report_skipped <<< "$counts"
        total=$((total + report_total))
        failed=$((failed + report_failed))
        skipped=$((skipped + report_skipped))
        written="$written$report"$'\n'
    done

    if [ "$seen" -eq 0 ]; then
        echo "UNVERIFIABLE  no JUnit report was written ($REQUESTED_REPORT, $SWIFT_TESTING_REPORT)"
        [ "$leak_rc" -ne 0 ] && return 1
        return 3
    fi

    local verdict verdict_rc
    verdict="$(junit_verdict "$total" "$failed" "$skipped" "$rc")"
    verdict_rc=$?
    echo "$verdict"

    # A skip is UNVERIFIABLE, and the message names the tests that did not run.
    if [ "$verdict_rc" -eq 3 ] && [ "$skipped" -gt 0 ]; then
        echo "skipped tests (not run, so not a pass):"
        printf '%s' "$written" | while IFS= read -r report; do
            [ -n "$report" ] || continue
            skipped_names "$report" | sed 's/^/              /'
        done
    fi

    if [ "$verdict_rc" -eq 0 ]; then
        printf '%s' "$written" | while IFS= read -r report; do
            [ -n "$report" ] && echo "report        $report"
        done
    fi

    # A leaked temp directory is a real failure, even beside a skip.
    if [ "$leak_rc" -ne 0 ]; then
        return 1
    fi
    return "$verdict_rc"
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
