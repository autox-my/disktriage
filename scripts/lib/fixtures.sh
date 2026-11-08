# shellcheck shell=bash
# Locates the NTFS live-test fixtures that scripts/bootstrap.sh builds.
#
# This mirrors Tests/TestSupport/TestFixtures.swift: the environment override
# wins, then the bootstrap output under `.build/`. `captures/` is never
# consulted, because it is untracked scratch that a fresh clone does not have.
#
# Sourced by scripts/check.sh (as the gate's preflight) and by
# scripts/check-gate-probe.sh (which proves the preflight bites).

fixtures_prefix_is_complete() {
    local prefix="$1"
    [ -n "$prefix" ] || return 1
    [ -x "$prefix/bin/ntfsinfo" ] || return 1
    [ -x "$prefix/bin/ntfsls" ] || return 1
    [ -x "$prefix/sbin/mkntfs" ] || return 1
    return 0
}

fixtures_native_dir_is_complete() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    [ -f "$dir/exfat-disk.img" ] || return 1
    [ -f "$dir/exfat-part.img" ] || return 1
    [ -f "$dir/fat-disk.img" ] || return 1
    [ -f "$dir/fat-part.img" ] || return 1
    [ -f "$dir/hfs-disk.dmg" ] || return 1
    [ -f "$dir/hfs-part.img" ] || return 1
    [ -f "$dir/apfs-disk.img" ] || return 1
    [ -f "$dir/encrypted-apfs.img" ] || return 1
    [ -f "$dir/damaged-exfat-part.img" ] || return 1
    [ -f "$dir/damaged-exfat-part.mapfile" ] || return 1
    return 0
}

fixtures_dir_is_complete() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    [ -f "$dir/disk.img" ] || return 1
    [ -f "$dir/damaged-clip-part.img" ] || return 1
    [ -f "$dir/damaged-clip-part.mapfile" ] || return 1
    return 0
}

# Echoes the prefix to use, or nothing. An environment override is final: an
# incomplete override returns nothing rather than silently falling back to the
# bootstrap output, so a typo cannot be hidden.
fixtures_ntfs_prefix() {
    local root="$1"
    if [ -n "${DISKTRIAGE_NTFS_PREFIX:-}" ]; then
        fixtures_prefix_is_complete "$DISKTRIAGE_NTFS_PREFIX" || return 1
        printf '%s\n' "$DISKTRIAGE_NTFS_PREFIX"
        return 0
    fi
    fixtures_prefix_is_complete "$root/.build/ntfs-prefix" || return 1
    printf '%s\n' "$root/.build/ntfs-prefix"
    return 0
}

fixtures_ntfs_dir() {
    local root="$1"
    if [ -n "${DISKTRIAGE_FIXTURE_DIR:-}" ]; then
        fixtures_dir_is_complete "$DISKTRIAGE_FIXTURE_DIR" || return 1
        printf '%s\n' "$DISKTRIAGE_FIXTURE_DIR"
        return 0
    fi
    fixtures_dir_is_complete "$root/.build/fixtures/ntfs" || return 1
    printf '%s\n' "$root/.build/fixtures/ntfs"
    return 0
}

fixtures_native_dir() {
    local root="$1"
    if [ -n "${DISKTRIAGE_NATIVE_FIXTURE_DIR:-}" ]; then
        fixtures_native_dir_is_complete "$DISKTRIAGE_NATIVE_FIXTURE_DIR" || return 1
        printf '%s\n' "$DISKTRIAGE_NATIVE_FIXTURE_DIR"
        return 0
    fi
    fixtures_native_dir_is_complete "$root/.build/fixtures/native" || return 1
    printf '%s\n' "$root/.build/fixtures/native"
    return 0
}

# Returns 0 when all three are present, or 3 with the instruction to bootstrap.
# It never returns 0 because `captures/` happens to exist.
fixtures_preflight() {
    local root="$1" prefix dir native
    prefix="$(fixtures_ntfs_prefix "$root")"
    local prefix_rc=$?
    dir="$(fixtures_ntfs_dir "$root")"
    local dir_rc=$?
    native="$(fixtures_native_dir "$root")"
    local native_rc=$?
    if [ "$prefix_rc" -eq 0 ] && [ "$dir_rc" -eq 0 ] && [ "$native_rc" -eq 0 ]; then
        return 0
    fi
    printf '%s\n' "UNVERIFIABLE  the live-test fixtures are not built."
    printf '%s\n' "              run: scripts/bootstrap.sh"
    printf '%s\n' "              looked for \$DISKTRIAGE_NTFS_PREFIX, \$DISKTRIAGE_FIXTURE_DIR"
    printf '%s\n' "              and \$DISKTRIAGE_NATIVE_FIXTURE_DIR, then"
    printf '%s\n' "              $root/.build/ntfs-prefix, $root/.build/fixtures/ntfs"
    printf '%s\n' "              and $root/.build/fixtures/native"
    return 3
}
