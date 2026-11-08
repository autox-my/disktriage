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
# shellcheck source=lib/native-leak.sh
. "$ROOT/scripts/lib/native-leak.sh"

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

# The native attach leak guard: an empty scan passes, an attached image or a
# leftover mountpoint fails and is named, and a scan that could not run is
# UNVERIFIABLE (3), never a pass. The probe uses fake scan files, never a real
# attached image.
native_clean="$TMP/native-clean.txt"
native_image="$TMP/native-image.txt"
native_mount="$TMP/native-mount.txt"
native_unverifiable="$TMP/native-unverifiable.txt"
printf 'CLEAN\n' >"$native_clean"
printf 'image /tmp/disktriage-tests-abc/leaked.img\n' >"$native_image"
printf 'mount /dev/disk9s1 on /tmp/disktriage-mount-abc (exfat, read-only)\n' >"$native_mount"
printf 'UNVERIFIABLE  hdiutil not found\n' >"$native_unverifiable"
native_empty="$TMP/native-empty.txt"
: >"$native_empty"

output="$(native_leak_verdict "$native_clean")"
got=$?
if [ "$got" -eq 0 ] && [[ "$output" == *"PASS"* ]]; then
    echo "ok   probe no native attach leftover -> 0"
else
    fail "no native attach leftover" "expected 0 PASS, got $got ($output)"
fi
output="$(native_leak_verdict "$native_image")"
got=$?
if [ "$got" -eq 1 ] && [[ "$output" == *"leaked.img"* ]]; then
    echo "ok   probe a leaked attached image -> 1"
else
    fail "leaked attached image" "expected 1 naming the image, got $got ($output)"
fi
output="$(native_leak_verdict "$native_mount")"
got=$?
if [ "$got" -eq 1 ] && [[ "$output" == *"disktriage-mount-abc"* ]]; then
    echo "ok   probe a leftover mountpoint -> 1"
else
    fail "leftover mountpoint" "expected 1 naming the mountpoint, got $got ($output)"
fi
output="$(native_leak_verdict "$native_unverifiable")"
got=$?
if [ "$got" -eq 3 ] && [[ "$output" == *"UNVERIFIABLE"* ]]; then
    echo "ok   probe native leak scan without hdiutil -> 3"
else
    fail "native leak scan without hdiutil" "expected 3, got $got ($output)"
fi
output="$(native_leak_verdict "$native_empty")"
got=$?
if [ "$got" -eq 3 ] && [[ "$output" == *"empty or unwritten"* ]]; then
    echo "ok   probe an unwritten native leak scan -> 3"
else
    fail "unwritten native leak scan" "expected 3, got $got ($output)"
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
cat >"$anchor_root/docs/sdlc.md" <<'DOC'
# The SDLC

## The gate

A claim may point at this section.

### Commands

The more specific heading wins when it encloses the line.
DOC
awk 'BEGIN{done=0} /^  source:/ && !done {print "  source: docs/sdlc.md#L5"; done=1; next} {print}' \
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
# The nearest (###) heading wins over the enclosing (##) one.
awk 'BEGIN{done=0} /^  source:/ && !done {print "  source: docs/sdlc.md#L9"; done=1; next} {print}' \
    "$ROOT/claims/REQ-0004.yml" >"$anchor_root/claims/REQ-0004.yml"
output="$("$ROOT/scripts/req-anchors.sh" --root "$anchor_root" --pending "$TMP/no-pending" --fix --only REQ-0004 2>&1)"
got=$?
expect_rc "req-anchors --fix prefers the most specific heading" 0 "$got" "$output" "FIXED"
if grep -q 'source: docs/sdlc.md#commands' "$anchor_root/claims/REQ-0004.yml"; then
    echo "ok   probe req-anchors --fix chose the ### heading"
else
    fail "req-anchors --fix specificity" "the source is not docs/sdlc.md#commands: $(grep 'source:' "$anchor_root/claims/REQ-0004.yml")"
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

# (f) The fixture preflight: an absent bootstrap output is UNVERIFIABLE (3)
# naming scripts/bootstrap.sh, never PASS and never FAIL; the environment
# override wins; and `captures/` is never consulted.
# shellcheck source=lib/fixtures.sh
. "$ROOT/scripts/lib/fixtures.sh"

make_fake_prefix() {
    mkdir -p "$1/bin" "$1/sbin"
    local tool
    for tool in bin/ntfsinfo bin/ntfsls sbin/mkntfs; do
        printf '#!/bin/sh\nexit 0\n' >"$1/$tool"
        chmod +x "$1/$tool"
    done
}
make_fake_fixtures() {
    mkdir -p "$1"
    : >"$1/disk.img"
    : >"$1/damaged-clip-part.img"
    : >"$1/damaged-clip-part.mapfile"
    local name
    for name in exfat-disk.img exfat-part.img fat-disk.img fat-part.img \
                hfs-disk.dmg hfs-part.img apfs-disk.img encrypted-apfs.img \
                damaged-exfat-part.img damaged-exfat-part.mapfile; do
        : >"$1/$name"
    done
}

fixture_root="$TMP/fixture-root"
mkdir -p "$fixture_root"
output="$(fixtures_preflight "$fixture_root")"
got=$?
expect_rc "fixtures preflight without bootstrap" 3 "$got" "$output" "scripts/bootstrap.sh"

make_fake_prefix "$fixture_root/.build/ntfs-prefix"
make_fake_fixtures "$fixture_root/.build/fixtures/ntfs"
make_fake_fixtures "$fixture_root/.build/fixtures/native"
output="$(fixtures_preflight "$fixture_root")"
got=$?
expect_rc "fixtures preflight with the bootstrap output" 0 "$got" "$output"

# captures/ alone is never enough, even when it is complete.
captures_root="$TMP/captures-root"
mkdir -p "$captures_root/captures/ntfs-spike"
make_fake_prefix "$captures_root/captures/ntfs-spike/prefix"
make_fake_fixtures "$captures_root/captures/ntfs-spike/img"
make_fake_fixtures "$captures_root/captures/ntfs-spike/native"
output="$(fixtures_preflight "$captures_root")"
got=$?
expect_rc "fixtures preflight never uses captures/" 3 "$got" "$output" "scripts/bootstrap.sh"

# The environment override wins; an incomplete override fails closed rather
# than silently using the bootstrap output.
env_prefix="$TMP/env-prefix"
env_fixtures="$TMP/env-fixtures"
env_native="$TMP/env-native"
make_fake_prefix "$env_prefix"
make_fake_fixtures "$env_fixtures"
make_fake_fixtures "$env_native"
env_root="$TMP/env-root"
mkdir -p "$env_root"
output="$(DISKTRIAGE_NTFS_PREFIX="$env_prefix" DISKTRIAGE_FIXTURE_DIR="$env_fixtures" \
    DISKTRIAGE_NATIVE_FIXTURE_DIR="$env_native" fixtures_preflight "$env_root")"
got=$?
expect_rc "fixtures preflight honours the environment" 0 "$got" "$output"
output="$(DISKTRIAGE_NTFS_PREFIX="$TMP/missing" DISKTRIAGE_FIXTURE_DIR="$env_fixtures" \
    DISKTRIAGE_NATIVE_FIXTURE_DIR="$env_native" fixtures_preflight "$fixture_root")"
got=$?
expect_rc "fixtures preflight fails closed on an incomplete override" 3 "$got" "$output" \
    "scripts/bootstrap.sh"
output="$(DISKTRIAGE_NTFS_PREFIX="$env_prefix" DISKTRIAGE_FIXTURE_DIR="$env_fixtures" \
    DISKTRIAGE_NATIVE_FIXTURE_DIR="$TMP/missing-native" fixtures_preflight "$fixture_root")"
got=$?
expect_rc "fixtures preflight fails closed on missing native fixtures" 3 "$got" "$output" \
    "scripts/bootstrap.sh"

# (g) The shell recipe and the Homebrew formula pin the same ntfs-3g tarball.
formula_pin="$(sed -n 's/.*sha256 "\([0-9a-f]\{64\}\)".*/\1/p' \
    "$ROOT/packaging/homebrew/Formula/disktriage.rb" | head -1)"
shell_pin="$(sed -n 's/^NTFS3G_SHA256="\([0-9a-f]\{64\}\)"/\1/p' \
    "$ROOT/scripts/lib/ntfs-3g.sh")"
if [ -n "$formula_pin" ] && [ "$formula_pin" = "$shell_pin" ]; then
    echo "ok   probe ntfs-3g pin matches the formula -> $shell_pin"
else
    fail "ntfs-3g pin" "formula '$formula_pin' != shell '$shell_pin'"
fi

if [ "$failures" -ne 0 ]; then
    echo "FAIL          $failures probe(s) failed"
    exit 1
fi
echo "PASS          the gate's pass/fail/skip, temp-leak and requirement rules bite"
