#!/usr/bin/env bash
# Shared by scripts/check.sh and scripts/check-gate-probe.sh.
#
# The native attach tests mount synthetic images. A leaked attached image or a
# leftover mountpoint is a bug: it keeps a kernel filesystem and a /dev node
# alive after the suite, and the next run could trip over it. This library
# scans the host's image inventory and mount table for anything whose path is
# ours (a `disktriage` test temp path or a `disktriage-mount-*` mountpoint).
#
# It never detaches or deletes anything: a leftover is reported, never cleaned
# by the gate, because the gate must not guess which disk is safe to eject.
#
# A missing hdiutil is UNVERIFIABLE (3), never a pass.

native_leak_scan() {
    local hdiutil="${HDIUTIL_BIN:-/usr/bin/hdiutil}"
    local mount_bin="${MOUNT_BIN:-/sbin/mount}"
    if [ ! -x "$hdiutil" ]; then
        echo "UNVERIFIABLE  hdiutil not found ($hdiutil); the attach leak guard cannot run"
        return 3
    fi
    if [ ! -x "$mount_bin" ]; then
        echo "UNVERIFIABLE  mount not found ($mount_bin); the mountpoint leak guard cannot run"
        return 3
    fi

    local found=0
    # `hdiutil info` blocks: image-path : <path>, then /dev/diskN lines. A
    # leaked test image is under a temp root and contains `disktriage`.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            *disktriage*)
                echo "image $path"
                found=1
                ;;
        esac
    done < <("$hdiutil" info 2>/dev/null | sed -n 's/^image-path *: *//p')

    # A leftover mountpoint is named disktriage-mount-* by the product and
    # disktriage-tests-* by a test-owned directory.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "mount $line"
        found=1
    done < <("$mount_bin" 2>/dev/null | grep -E 'disktriage-(mount|tests)' || true)

    if [ "$found" -eq 0 ]; then
        echo "CLEAN"
    fi
    return 0
}

# Decides a scan file produced by native_leak_scan. Prints PASS/FAIL and
# returns 0 when nothing was left attached, 1 when something was, 3 when the
# scan could not run.
native_leak_verdict() {
    local scan="$1"
    if [ ! -f "$scan" ]; then
        echo "UNVERIFIABLE  the native attach leak scan produced no file"
        return 3
    fi
    if grep -q '^UNVERIFIABLE' "$scan"; then
        cat "$scan"
        return 3
    fi
    local count
    count="$(grep -cE '^(image|mount) ' "$scan" || true)"
    if [ "${count:-0}" -gt 0 ]; then
        echo "FAIL          $count native attach leftover(s) (an attached image or a mountpoint):"
        grep -E '^(image|mount) ' "$scan" | sed 's/^/              /'
        return 1
    fi
    if ! grep -q '^CLEAN$' "$scan"; then
        echo "UNVERIFIABLE  the native attach leak scan is empty or unwritten"
        return 3
    fi
    echo "PASS          no native image or mountpoint left attached"
    return 0
}
