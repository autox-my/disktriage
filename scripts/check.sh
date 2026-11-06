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

# Counts one report. Prints "<total> <not-passed>".
count_report() {
    local report="$1" total bad
    total="$("$XMLLINT_BIN" --noout --xpath 'count(//testcase)' "$report" 2>"$LOG_DIR/xpath.log")" || {
        echo "UNVERIFIABLE  cannot parse $report: $(tr '\n' ' ' <"$LOG_DIR/xpath.log")"
        return 3
    }
    bad="$("$XMLLINT_BIN" --noout --xpath 'count(//testcase[failure or error or skipped])' "$report" 2>>"$LOG_DIR/xpath.log")" || {
        echo "UNVERIFIABLE  cannot parse $report: $(tr '\n' ' ' <"$LOG_DIR/xpath.log")"
        return 3
    }
    printf '%s %s\n' "$total" "$bad"
}

run_tests() {
    echo "== test =="
    mkdir -p "$REPORT_DIR" || {
        echo "UNVERIFIABLE  cannot create $REPORT_DIR"
        return 3
    }
    rm -f "$REQUESTED_REPORT" "$SWIFT_TESTING_REPORT"

    "$SWIFT_BIN" test --xunit-output "$REQUESTED_REPORT" >"$TEST_LOG" 2>&1
    local rc=$?
    cat "$TEST_LOG"

    local report total=0 bad=0 seen=0 counts written=""
    for report in "$REQUESTED_REPORT" "$SWIFT_TESTING_REPORT"; do
        if [ ! -s "$report" ]; then
            continue
        fi
        counts="$(count_report "$report")"
        case "$?" in
            0) ;;
            *) echo "$counts"; return 3 ;;
        esac
        seen=$((seen + 1))
        total=$((total + ${counts% *}))
        bad=$((bad + ${counts#* }))
        written="$written$report"$'\n'
    done

    if [ "$seen" -eq 0 ]; then
        echo "UNVERIFIABLE  no JUnit report was written ($REQUESTED_REPORT, $SWIFT_TESTING_REPORT)"
        return 3
    fi
    if [ "$total" -le 0 ]; then
        echo "UNVERIFIABLE  the report carries no test cases"
        return 3
    fi
    if [ "$bad" -ne 0 ]; then
        echo "FAIL          $bad of $total tests failed or were skipped"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "FAIL          swift test exited $rc although the report shows $total passing tests"
        return 1
    fi
    echo "PASS          $total tests, 0 failures"
    printf '%s' "$written" | while IFS= read -r report; do
        [ -n "$report" ] && echo "report        $report"
    done
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
