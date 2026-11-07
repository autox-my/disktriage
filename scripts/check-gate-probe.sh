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

REQ_BIN="${REQ_BIN:-$(command -v req 2>/dev/null || true)}"
if [ -z "$REQ_BIN" ] || [ ! -x "$REQ_BIN" ]; then
    echo "UNVERIFIABLE  req not found (set REQ_BIN)"
    exit 3
fi

# shellcheck source=lib/junit-report.sh
. "$ROOT/scripts/lib/junit-report.sh"
# shellcheck source=lib/temp-leak.sh
. "$ROOT/scripts/lib/temp-leak.sh"

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

# The leak guard: a pre-existing `disktriage-*` directory is a warning and not
# a failure; a directory the run added is FAIL (1) and is named. The probe uses
# a fake root, never a real temp-directory leftover.
probe_root="$TMP/temp-root"
mkdir -p "$probe_root/disktriage-preexisting"
leak_before="$TMP/leak-before.txt"
leak_clean="$TMP/leak-clean.txt"
leak_dirty="$TMP/leak-dirty.txt"
temp_leak_list "$probe_root" >"$leak_before"
temp_leak_list "$probe_root" >"$leak_clean"

output="$(temp_leak_verdict "$leak_before" "$leak_clean")"
got=$?
if [ "$got" -ne 0 ]; then
    fail "no new temp directory" "expected exit 0, got $got ($output)"
elif [[ "$output" != *"pre-existing"* ]] || [[ "$output" != *"PASS"* ]]; then
    fail "no new temp directory" "expected a pre-existing warning and PASS: $output"
else
    echo "ok   probe no new temp directory -> 0: $(printf '%s' "$output" | tr '\n' ' ')"
fi

mkdir -p "$probe_root/disktriage-new-leftover"
temp_leak_list "$probe_root" >"$leak_dirty"
output="$(temp_leak_verdict "$leak_before" "$leak_dirty")"
got=$?
if [ "$got" -ne 1 ]; then
    fail "new temp directory" "expected exit 1, got $got ($output)"
elif [[ "$output" != *"1 new"* ]] || [[ "$output" != *"disktriage-new-leftover"* ]]; then
    fail "new temp directory" "expected the count and the name: $output"
elif [[ "$output" == *"disktriage-preexisting"* ]]; then
    fail "new temp directory" "a pre-existing directory was reported as new: $output"
else
    echo "ok   probe new temp directory -> 1: $(printf '%s' "$output" | tr '\n' ' ')"
fi

# The requirement steps: each probe runs the real script over a temporary
# corpus, never the repository's claims/ or docs/.
expect_rc() {
    local name="$1" expected="$2" got="$3" output="$4" needle="${5:-}"
    if [ "$got" -ne "$expected" ]; then
        fail "$name" "expected exit $expected, got $got ($output)"
        return
    fi
    if [ -n "$needle" ] && [[ "$output" != *"$needle"* ]]; then
        fail "$name" "output does not contain '$needle': $output"
        return
    fi
    echo "ok   probe $name -> $got"
}

req_corpus="$TMP/req-corpus"
mkdir -p "$req_corpus/claims" "$req_corpus/aliases" "$req_corpus/.build/test-results"
cp "$ROOT/aliases/subjects.yml" "$req_corpus/aliases/subjects.yml"
cp "$ROOT/claims/REQ-0004.yml" "$req_corpus/claims/REQ-0004.yml"

# (a) req canon --fail-on-flag: a contradictory pin is a flag (exit 1).
printf 'pins:\n  modality: "SHALL-NOT"\n' >>"$req_corpus/claims/REQ-0004.yml"
output="$("$REQ_BIN" --root "$req_corpus" canon --fail-on-flag 2>&1)"
got=$?
expect_rc "req canon flags a contradictory pin" 1 "$got" "$output" "flagged"
cp "$ROOT/claims/REQ-0004.yml" "$req_corpus/claims/REQ-0004.yml"

# (b) req-link --check: the report names a different id than the tests: list.
cat >"$req_corpus/.build/test-results/report.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites><testsuite name="S"><testcase classname="M.S" name="REQ0004_other()" time="0"/></testsuite></testsuites>
XML
output="$("$ROOT/scripts/req-link.sh" --root "$req_corpus" --check 2>&1)"
got=$?
expect_rc "req-link detects a drifted tests: list" 1 "$got" "$output" "drifts"

# (c) req gate --test-report: an unlinked claim is UNVERIFIABLE (3), named.
awk '/^tests:/{exit} {print}' "$ROOT/claims/REQ-0004.yml" \
    >"$req_corpus/claims/REQ-0004.yml"
cat >"$req_corpus/.build/test-results/report.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites><testsuite name="S"><testcase classname="M.S" name="unrelated()" time="0"/></testsuite></testsuites>
XML
output="$("$REQ_BIN" --root "$req_corpus" gate --test-report "$req_corpus/.build/test-results/report.xml" 2>&1)"
got=$?
expect_rc "req gate reports an unlinked claim" 3 "$got" "$output" "no linked test"

# (d) req-anchors --check: a #L anchor outside the pending list fails; the
# pending list tolerates it; --fix converts it to the enclosing heading.
anchor_root="$TMP/anchor-corpus"
mkdir -p "$anchor_root/claims" "$anchor_root/docs"
cp "$ROOT/docs/sdlc.md" "$anchor_root/docs/sdlc.md"
awk 'BEGIN{done=0} /^  source:/ && !done {print "  source: docs/sdlc.md#L7"; done=1; next} {print}' \
    "$ROOT/claims/REQ-0004.yml" >"$anchor_root/claims/REQ-0004.yml"
output="$("$ROOT/scripts/req-anchors.sh" --root "$anchor_root" --pending "$TMP/no-pending" --check 2>&1)"
got=$?
expect_rc "req-anchors rejects a #L anchor outside pending" 1 "$got" "$output" "line anchor"
printf 'REQ-0004\n' >"$TMP/pending"
output="$("$ROOT/scripts/req-anchors.sh" --root "$anchor_root" --pending "$TMP/pending" --check 2>&1)"
got=$?
expect_rc "req-anchors tolerates a pending #L anchor" 0 "$got" "$output" "pending"
output="$("$ROOT/scripts/req-anchors.sh" --root "$anchor_root" --pending "$TMP/pending" --fix --only REQ-0004 2>&1)"
got=$?
expect_rc "req-anchors --fix rewrites to the enclosing heading" 0 "$got" "$output" "FIXED"
if grep -q 'source: docs/sdlc.md#the-gate' "$anchor_root/claims/REQ-0004.yml"; then
    echo "ok   probe req-anchors --fix wrote the section anchor"
else
    fail "req-anchors --fix" "the source is not docs/sdlc.md#the-gate: $(grep 'source:' "$anchor_root/claims/REQ-0004.yml")"
fi
output="$("$ROOT/scripts/req-anchors.sh" --root "$anchor_root" --pending "$TMP/no-pending" --check 2>&1)"
got=$?
expect_rc "req-anchors accepts the fixed section anchor" 0 "$got" "$output" "0 findings"

# (e) req-counts --check: a stale block is 1; --write makes it current; a
# missing req is UNVERIFIABLE (3), never a pass.
counts_root="$TMP/counts-corpus"
mkdir -p "$counts_root/claims" "$counts_root/aliases" "$counts_root/docs"
cp "$ROOT/aliases/subjects.yml" "$counts_root/aliases/subjects.yml"
cp "$ROOT/claims/REQ-0004.yml" "$counts_root/claims/REQ-0004.yml"
cat >"$counts_root/docs/req-workflow.md" <<'DOC'
# Requirements workflow

## Current state

<!-- req-counts:begin -->
- 999 claims total.
<!-- req-counts:end -->
DOC
output="$("$ROOT/scripts/req-counts.sh" --root "$counts_root" --check 2>&1)"
got=$?
expect_rc "req-counts rejects a stale block" 1 "$got" "$output" "stale"
output="$("$ROOT/scripts/req-counts.sh" --root "$counts_root" --write 2>&1)"
got=$?
expect_rc "req-counts --write regenerates the block" 0 "$got" "$output" "wrote"
output="$("$ROOT/scripts/req-counts.sh" --root "$counts_root" --check 2>&1)"
got=$?
expect_rc "req-counts accepts the regenerated block" 0 "$got" "$output" "current"
output="$(REQ_BIN=/nonexistent "$ROOT/scripts/req-counts.sh" --root "$counts_root" --check 2>&1)"
got=$?
expect_rc "req-counts is UNVERIFIABLE without req" 3 "$got" "$output" "UNVERIFIABLE"

if [ "$failures" -ne 0 ]; then
    echo "FAIL          $failures probe(s) failed"
    exit 1
fi
echo "PASS          the gate's pass/fail/skip, temp-leak and requirement rules bite"
