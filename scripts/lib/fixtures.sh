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

# Returns 0 when both are present, or 3 with the instruction to bootstrap.
# It never returns 0 because `captures/` happens to exist.
fixtures_preflight() {
    local root="$1" prefix dir
    prefix="$(fixtures_ntfs_prefix "$root")"
    local prefix_rc=$?
    dir="$(fixtures_ntfs_dir "$root")"
    local dir_rc=$?
    if [ "$prefix_rc" -eq 0 ] && [ "$dir_rc" -eq 0 ]; then
        return 0
    fi
    printf '%s\n' "UNVERIFIABLE  the NTFS live-test fixtures are not built."
    printf '%s\n' "              run: scripts/bootstrap.sh"
    printf '%s\n' "              looked for \$DISKTRIAGE_NTFS_PREFIX and \$DISKTRIAGE_FIXTURE_DIR,"
    printf '%s\n' "              then $root/.build/ntfs-prefix and $root/.build/fixtures/ntfs"
    return 3
}
