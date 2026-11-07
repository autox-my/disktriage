#!/usr/bin/env bash
# JUnit-report reading for the gate (`scripts/check.sh`) and its probe
# (`scripts/check-gate-probe.sh`). No side effects on source or reports.
#
# The caller sets XMLLINT_BIN. A report that cannot be parsed is UNVERIFIABLE
# (3), never a pass.

# count_report <report>
#   stdout: "<total> <failed> <skipped>"
#   return: 0 parsed, 3 unparsable (with the reason on stdout)
count_report() {
    local report="$1" total failed skipped err
    err="$(mktemp)" || {
        echo "UNVERIFIABLE  cannot create a temporary file"
        return 3
    }

    total="$("$XMLLINT_BIN" --noout --xpath 'count(//testcase)' "$report" 2>"$err")" || {
        echo "UNVERIFIABLE  cannot parse $report: $(tr '\n' ' ' <"$err")"
        rm -f "$err"
        return 3
    }
    failed="$("$XMLLINT_BIN" --noout --xpath 'count(//testcase[failure or error])' "$report" 2>>"$err")" || {
        echo "UNVERIFIABLE  cannot parse $report: $(tr '\n' ' ' <"$err")"
        rm -f "$err"
        return 3
    }
    skipped="$("$XMLLINT_BIN" --noout --xpath 'count(//testcase[skipped])' "$report" 2>>"$err")" || {
        echo "UNVERIFIABLE  cannot parse $report: $(tr '\n' ' ' <"$err")"
        rm -f "$err"
        return 3
    }
    rm -f "$err"
    printf '%s %s %s\n' "$total" "$failed" "$skipped"
}

# skipped_names <report>
#   stdout: one "classname::name" per skipped test case.
skipped_names() {
    local report="$1"
    paste -d ':' \
        <("$XMLLINT_BIN" --noout --xpath '//testcase[skipped]/@classname' "$report" 2>/dev/null \
            | sed -n 's/^ *classname="\(.*\)"$/\1/p') \
        <("$XMLLINT_BIN" --noout --xpath '//testcase[skipped]/@name' "$report" 2>/dev/null \
            | sed -n 's/^ *name="\(.*\)"$/\1/p') \
        | sed 's/^\([^:]*\):/\1::/'
}

# junit_verdict <total> <failed> <skipped> <runner-rc>
#   stdout: one decision line
#   return: 0 PASS, 1 FAIL, 3 UNVERIFIABLE
#
# A failure/error outranks a skip (a real failure is 1 even beside a skip).
# A skip with no failure is UNVERIFIABLE (3), never PASS and never FAIL: the
# test did not run, so the gate cannot say it passed or failed.
junit_verdict() {
    local total="$1" failed="$2" skipped="$3" rc="$4"

    if [ "$total" -le 0 ]; then
        echo "UNVERIFIABLE  the report carries no test cases"
        return 3
    fi
    if [ "$failed" -ne 0 ]; then
        if [ "$skipped" -ne 0 ]; then
            echo "FAIL          $failed of $total tests failed or errored ($skipped skipped)"
        else
            echo "FAIL          $failed of $total tests failed or errored"
        fi
        return 1
    fi
    if [ "$skipped" -ne 0 ]; then
        echo "UNVERIFIABLE  $skipped of $total tests were skipped"
        return 3
    fi
    if [ "$rc" -ne 0 ]; then
        echo "FAIL          swift test exited $rc although the report shows $total passing tests"
        return 1
    fi
    echo "PASS          $total tests, 0 failures"
    return 0
}
