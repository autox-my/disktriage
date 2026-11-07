#!/usr/bin/env bash
# Shared by scripts/check.sh and scripts/check-gate-probe.sh.
#
# The gate must not leak gigabytes into the user's temp directory. This library
# lists the `disktriage-*` directories directly under each temp root and
# answers whether the test run added any. It never deletes anything: a
# pre-existing directory is a warning, not the gate's property.
#
# A skipped check is never a pass; a leaked directory is a FAIL (1), even when
# the tests themselves were skipped (3), because a real failure beside a skip is
# still a failure.

# The temp roots to inspect: `getconf DARWIN_USER_TEMP_DIR` and `$TMPDIR`, once
# each, and only when the directory exists. An empty or missing root is not a
# pass; the caller's gate still decides from the report.
temp_leak_roots() {
    local root seen=" "
    for root in "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)" "${TMPDIR:-}"; do
        [ -n "$root" ] || continue
        root="${root%/}"
        [ -d "$root" ] || continue
        case "$seen" in
            *" $root "*) continue ;;
        esac
        seen="$seen$root "
        printf '%s\n' "$root"
    done
}

# Prints the absolute path of every immediate `disktriage-*` directory under
# $1, sorted. Files are not counted: a test image is a file, and the plan's
# leak is a directory tree.
temp_leak_list() {
    local root="$1"
    [ -d "$root" ] || return 0
    find "$root" -mindepth 1 -maxdepth 1 -type d -name 'disktriage-*' -print \
        | LC_ALL=C sort
}

# Prints the absolute path of every `disktriage-*` directory under every temp
# root, sorted. This is the snapshot the gate compares before and after the run.
temp_leak_snapshot() {
    local root
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        temp_leak_list "$root"
    done < <(temp_leak_roots)
}

# Compares two snapshots (files produced by temp_leak_snapshot). $1 is before,
# $2 is after. Prints a PASS/FAIL (and a WARN for pre-existing entries) and
# returns 1 when the run added a directory, 0 when it did not.
temp_leak_verdict() {
    local before="$1" after="$2"
    local pre new count

    pre="$(wc -l <"$before" | tr -d ' ')"
    if [ "${pre:-0}" -gt 0 ]; then
        echo "WARN          $pre pre-existing disktriage-* director$([ "$pre" -eq 1 ] && echo y || echo ies) in the temp directory (not deleted by the gate)"
    fi
    new="$(LC_ALL=C comm -13 "$before" "$after")"
    if [ -n "$new" ]; then
        count="$(printf '%s\n' "$new" | wc -l | tr -d ' ')"
        echo "FAIL          $count new disktriage-* director$([ "$count" -eq 1 ] && echo y || echo ies) left in the temp directory:"
        printf '%s\n' "$new" | sed 's/^/              /'
        return 1
    fi

    echo "PASS          no new disktriage-* directories in the temp directory"
    return 0
}
