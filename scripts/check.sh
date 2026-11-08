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

# The requirement steps use `req` and three read-only scripts. A missing `req`
# is UNVERIFIABLE (3), never a pass and never a silent skip to 0; each step
# says so itself, so one missing tool does not hide the other steps' outcomes.
REQ_BIN="${REQ_BIN:-$(command -v req 2>/dev/null || true)}"

# The live NTFS tests need the prefix and images scripts/bootstrap.sh builds.
# Without them the suite cannot run the same tests as a prepared checkout, so
# the gate is UNVERIFIABLE (3) and names the one command that fixes it. It is
# never 0 (a silent skip) and never 1 (a missing fixture is not a failure).
# shellcheck source=lib/fixtures.sh
. "$ROOT/scripts/lib/fixtures.sh"
PREFLIGHT_OUTPUT="$(fixtures_preflight "$ROOT")"
PREFLIGHT_RC=$?
if [ "$PREFLIGHT_RC" -ne 0 ]; then
    echo "$PREFLIGHT_OUTPUT"
    echo "UNVERIFIABLE"
    exit 3
fi
export DISKTRIAGE_NTFS_PREFIX="$(fixtures_ntfs_prefix "$ROOT")"
export DISKTRIAGE_FIXTURE_DIR="$(fixtures_ntfs_dir "$ROOT")"
export DISKTRIAGE_NATIVE_FIXTURE_DIR="$(fixtures_native_dir "$ROOT")"

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
# shellcheck source=lib/native-leak.sh
. "$ROOT/scripts/lib/native-leak.sh"
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

    # A native attach or mount the suite leaked is a failure, like a leaked
    # temp directory. A scan that cannot run is UNVERIFIABLE, never a pass.
    local native_scan="$LOG_DIR/native-leak.txt" native_rc=0 native_output
    native_leak_scan >"$native_scan"
    native_output="$(native_leak_verdict "$native_scan")"
    native_rc=$?
    case "$native_rc" in
        0|1|3) ;;
        *)
            echo "UNVERIFIABLE  the native attach leak scan could not run (exit $native_rc)"
            native_rc=3
            ;;
    esac
    echo "$native_output"

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

    # A leaked temp directory or a leaked native attach is a real failure,
    # even beside a skip. A scan that could not run is UNVERIFIABLE.
    if [ "$leak_rc" -ne 0 ] || [ "$native_rc" -eq 1 ]; then
        return 1
    fi
    if [ "$native_rc" -eq 3 ] && [ "$verdict_rc" -ne 1 ]; then
        return 3
    fi
    return "$verdict_rc"
}

# The requirement steps run after the suite because the suite's JUnit report is
# their evidence. They are read-only: req canon/link/gate and the anchor and
# count checks never write the corpus. The JUnit report the test step wrote is
# the input, so a missing or zero-testcase report stays UNVERIFIABLE.
run_req_canon() {
    echo "== req canon =="
    if [ -z "$REQ_BIN" ] || [ ! -x "$REQ_BIN" ]; then
        echo "UNVERIFIABLE  req canon (req not found; set REQ_BIN)"
        return 3
    fi
    local log="$LOG_DIR/req-canon.log" rc
    "$REQ_BIN" --root "$ROOT" canon --fail-on-flag >"$log" 2>&1
    rc=$?
    case "$rc" in
        0) echo "PASS          req canon --fail-on-flag (0 flagged pins)" ;;
        *)
            cat "$log"
            echo "FAIL          req canon --fail-on-flag exited $rc (a flagged pin is a finding)"
            return 1
            ;;
    esac
    return 0
}

run_req_link() {
    echo "== req link =="
    local log="$LOG_DIR/req-link.log" rc
    "$ROOT/scripts/req-link.sh" --check >"$log" 2>&1
    rc=$?
    cat "$log"
    case "$rc" in
        0) echo "PASS          req-link --check" ;;
        1) echo "FAIL          req-link --check reports drift"; return 1 ;;
        3) echo "UNVERIFIABLE  req-link --check (no usable JUnit report)"; return 3 ;;
        *) echo "FAIL          req-link --check exited $rc"; return 1 ;;
    esac
    return 0
}

run_req_gate() {
    echo "== req gate =="
    if [ -z "$REQ_BIN" ] || [ ! -x "$REQ_BIN" ]; then
        echo "UNVERIFIABLE  req gate (req not found; set REQ_BIN)"
        return 3
    fi
    local log="$LOG_DIR/req-gate.log" rc
    "$REQ_BIN" --root "$ROOT" gate --test-report "$SWIFT_TESTING_REPORT" >"$log" 2>&1
    rc=$?
    cat "$log"
    case "$rc" in
        0) echo "PASS          req gate" ;;
        1) echo "FAIL          req gate (a flagged pin, a linked test failed, or an undecided claim)"; return 1 ;;
        3)
            echo "UNVERIFIABLE  req gate (exit 3; unlinked claims or stale links are named above)"
            return 3
            ;;
        *) echo "FAIL          req gate exited $rc"; return 1 ;;
    esac
    return 0
}

run_req_anchors() {
    echo "== req anchors =="
    local log="$LOG_DIR/req-anchors.log" rc
    "$ROOT/scripts/req-anchors.sh" --check >"$log" 2>&1
    rc=$?
    cat "$log"
    case "$rc" in
        0) echo "PASS          req-anchors --check" ;;
        1) echo "FAIL          req-anchors --check (an unresolved or line anchor outside the pending list)"; return 1 ;;
        3) echo "UNVERIFIABLE  req-anchors --check (no corpus)"; return 3 ;;
        *) echo "FAIL          req-anchors --check exited $rc"; return 1 ;;
    esac
    return 0
}

run_req_counts() {
    echo "== req counts =="
    local log="$LOG_DIR/req-counts.log" rc
    "$ROOT/scripts/req-counts.sh" --check >"$log" 2>&1
    rc=$?
    cat "$log"
    case "$rc" in
        0) echo "PASS          req-counts --check" ;;
        1) echo "FAIL          req-counts --check (the docs block is stale; run scripts/req-counts.sh --write)"; return 1 ;;
        3) echo "UNVERIFIABLE  req-counts --check (req or claims missing)"; return 3 ;;
        *) echo "FAIL          req-counts --check exited $rc"; return 1 ;;
    esac
    return 0
}

run_build
build_rc=$?
if [ "$build_rc" -ne 0 ]; then
    echo "FAIL"
    exit 1
fi

run_tests
test_rc=$?
run_req_canon
canon_rc=$?
run_req_link
link_rc=$?
run_req_gate
gate_rc=$?
run_req_anchors
anchors_rc=$?
run_req_counts
counts_rc=$?

# Precedence: a definite failure outranks UNVERIFIABLE, and UNVERIFIABLE
# outranks PASS. The final word names every step that did not pass.
failed=""
unverifiable=""
for step in test:"$test_rc" canon:"$canon_rc" link:"$link_rc" \
            gate:"$gate_rc" anchors:"$anchors_rc" counts:"$counts_rc"; do
    name="${step%%:*}"
    rc="${step##*:}"
    case "$rc" in
        0) ;;
        1) failed="$failed $name" ;;
        *) unverifiable="$unverifiable $name" ;;
    esac
done

if [ -n "$failed" ]; then
    echo "FAIL          step(s):$failed"
    echo "FAIL"
    exit 1
fi
if [ -n "$unverifiable" ]; then
    echo "UNVERIFIABLE  step(s):$unverifiable"
    echo "UNVERIFIABLE"
    exit 3
fi
echo "PASS"
exit 0
