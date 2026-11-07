#!/usr/bin/env bash
# Proves the gate's report rule bites: a skip is UNVERIFIABLE (3), never PASS
# and never FAIL; a real failure is FAIL (1) even beside a skip; all-pass is 0.
#
# It uses faked JUnit reports and the same functions scripts/check.sh calls
# (scripts/lib/junit-report.sh), so it exercises the gate's rule without
# running the suite.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
    echo "UNVERIFIABLE  cannot resolve the repository root"
    exit 3
}

XMLLINT_BIN="${XMLLINT_BIN:-$(command -v xmllint 2>/dev/null || true)}"
if [ -z "$XMLLINT_BIN" ] || [ ! -x "$XMLLINT_BIN" ]; then
    echo "UNVERIFIABLE  xmllint not found (set XMLLINT_BIN)"
    exit 3
fi

# shellcheck source=lib/junit-report.sh
. "$ROOT/scripts/lib/junit-report.sh"

TMP="$(mktemp -d)" || {
    echo "UNVERIFIABLE  cannot create a temporary directory"
    exit 3
}
trap 'rm -rf "$TMP"' EXIT

failures=0

report_pass="$TMP/pass.xml"
report_skip="$TMP/skip.xml"
report_fail_skip="$TMP/fail-skip.xml"
report_empty="$TMP/empty.xml"
report_broken="$TMP/broken.xml"

cat >"$report_pass" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="S" tests="2">
    <testcase classname="M.S" name="one()" time="0.01"/>
    <testcase classname="M.S" name="two()" time="0.01"/>
  </testsuite>
</testsuites>
XML

cat >"$report_skip" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="S" tests="2">
    <testcase classname="M.S" name="one()" time="0.01"/>
    <testcase classname="DiskTriageCLITests.InspectLiveTests" name="liveInspection()" time="0">
      <skipped message="ntfs-3g tools not available"/>
    </testcase>
  </testsuite>
</testsuites>
XML

cat >"$report_fail_skip" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="S" tests="2">
    <testcase classname="M.S" name="one()" time="0.01"><failure message="boom"/></testcase>
    <testcase classname="DiskTriageCLITests.InspectLiveTests" name="liveInspection()" time="0">
      <skipped message="ntfs-3g tools not available"/>
    </testcase>
  </testsuite>
</testsuites>
XML

cat >"$report_empty" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="S" tests="0"/>
</testsuites>
XML

printf '<testsuites><testsuite>' >"$report_broken"

fail() {
    echo "FAIL probe $1: $2"
    failures=$((failures + 1))
}

expect_counts() {
    local name="$1" report="$2" expected="$3" output rc
    output="$(count_report "$report")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name" "count_report exited $rc: $output"
        return
    fi
    if [ "$output" != "$expected" ]; then
        fail "$name" "expected counts '$expected', got '$output'"
        return
    fi
    echo "ok   probe $name -> $output"
}

expect_verdict() {
    local name="$1" expected="$2" total="$3" failed="$4" skipped="$5" rc="$6" needle="${7:-}"
    local output got
    output="$(junit_verdict "$total" "$failed" "$skipped" "$rc")"
    got=$?
    if [ "$got" -ne "$expected" ]; then
        fail "$name" "expected exit $expected, got $got ($output)"
        return
    fi
    if [ -n "$needle" ] && [[ "$output" != *"$needle"* ]]; then
        fail "$name" "output does not contain '$needle': $output"
        return
    fi
    echo "ok   probe $name -> $got: $output"
}

expect_counts "all-pass counts" "$report_pass" "2 0 0"
expect_counts "skip counts" "$report_skip" "2 0 1"
expect_counts "failure+skip counts" "$report_fail_skip" "2 1 1"
expect_counts "zero-testcase counts" "$report_empty" "0 0 0"

if count_report "$report_broken" >/dev/null 2>&1; then
    fail "unparsable report" "count_report accepted a broken report"
else
    rc=$?
    if [ "$rc" -eq 3 ]; then
        echo "ok   probe unparsable report -> 3"
    else
        fail "unparsable report" "expected 3, got $rc"
    fi
fi

expect_verdict "all-pass" 0 2 0 0 0 "PASS"
expect_verdict "skip only" 3 2 0 1 0 "UNVERIFIABLE"
expect_verdict "failure beside skip" 1 2 1 1 0 "FAIL"
expect_verdict "zero testcases" 3 0 0 0 0 "UNVERIFIABLE"
expect_verdict "runner failed with a green report" 1 2 0 0 1 "FAIL"

names="$(skipped_names "$report_skip")"
if [[ "$names" == *"DiskTriageCLITests.InspectLiveTests::liveInspection()"* ]]; then
    echo "ok   probe skipped names -> $names"
else
    fail "skipped names" "expected the skipped test id, got '$names'"
fi

if [ "$failures" -ne 0 ]; then
    echo "FAIL          $failures probe(s) failed"
    exit 1
fi
echo "PASS          the gate's pass/fail/skip rule bites"
