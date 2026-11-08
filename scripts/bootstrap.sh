#!/usr/bin/env bash
# bootstrap.sh — build the NTFS live-test fixtures from a fresh clone.
#
#   scripts/bootstrap.sh
#
# One documented setup command. It:
#   1. builds the pinned ntfs-3g userspace tools into .build/ntfs-prefix,
#      downloading only the sha256-verified tarball (cached under .build/);
#   2. builds the tracked fixture helper with the system clang and generates
#      the synthetic NTFS images under .build/fixtures/ntfs;
#   3. checks that the Homebrew dependencies ddrescue and smartctl exist.
#
# It is idempotent: a second run reuses the prefix and the generated images.
# It never uses sudo, never mounts anything and never touches /dev.
#
# Environment:
#   DISKTRIAGE_NTFS_PREFIX   build/use this prefix instead of .build/ntfs-prefix
#   DISKTRIAGE_FIXTURE_DIR   generate/use images here instead of .build/fixtures/ntfs
#
# Exit: 0 PASS, 1 FAIL (a required tool is missing or a build failed).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
    echo "FAIL          cannot resolve the repository root"
    exit 1
}

# shellcheck source=lib/ntfs-3g.sh
. "$ROOT/scripts/lib/ntfs-3g.sh"

PREFIX="${DISKTRIAGE_NTFS_PREFIX:-$ROOT/.build/ntfs-prefix}"
FIXTURE_DIR="${DISKTRIAGE_FIXTURE_DIR:-$ROOT/.build/fixtures/ntfs}"
CACHE_DIR="$ROOT/.build/ntfs-cache"
BUILD_DIR="$ROOT/.build/ntfs-build"
HELPER_DIR="$ROOT/.build/ntfs-fixture"
HELPER="$HELPER_DIR/nfixture"
GENERATOR="$ROOT/tools/ntfs-fixture/generate.sh"
NFIXTURE_C="$ROOT/tools/ntfs-fixture/nfixture.c"

note() { printf '%s\n' "$*"; }
die() { note "FAIL          $*"; exit 1; }

# --print-recipe is for humans and the packaging docs; it proves the shell
# recipe and the formula's resource block agree on the pin.
if [ "${1:-}" = "--print-recipe" ]; then
    note "ntfs-3g $NTFS3G_VERSION"
    note "url    $NTFS3G_URL"
    note "sha256 $NTFS3G_SHA256"
    note "configure:"
    ntfs3g_configure_flags '<prefix>' | sed 's/^/  /'
    exit 0
fi

# The tests need these; they are the formula's runtime dependencies.
missing=""
for tool in ddrescue smartctl; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    note "FAIL          missing required tool(s):$missing"
    note "              install them with: brew install ddrescue smartmontools"
    exit 1
fi

for tool in clang make tar shasum curl python3; do
    command -v "$tool" >/dev/null 2>&1 || die "missing build tool: $tool"
done

# 1. ntfs-3g userspace tools.
note "== ntfs-3g $NTFS3G_VERSION =="
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
ntfs3g_build "$PREFIX" "$CACHE_DIR" "$BUILD_DIR" "$jobs" || {
    note "FAIL          building ntfs-3g failed; see $BUILD_DIR/*.log"
    exit 1
}
note "PASS          ntfs-3g prefix $PREFIX"

# 2. The fixture helper. Static libntfs-3g, so the binary is relocatable; the
#    only non-libSystem dependency is CoreFoundation, which the library's
#    Darwin name-normalisation code uses.
note "== fixture helper =="
mkdir -p "$HELPER_DIR" || die "cannot create $HELPER_DIR"
if [ ! -x "$HELPER" ] || [ "$NFIXTURE_C" -nt "$HELPER" ]; then
    clang -O2 -I"$PREFIX/include" -o "$HELPER" "$NFIXTURE_C" \
        "$PREFIX/lib/libntfs-3g.a" -framework CoreFoundation \
        || die "cannot build the fixture helper with clang"
fi
note "PASS          fixture helper $HELPER"

# 3. The synthetic images.
note "== fixtures =="
"$GENERATOR" "$PREFIX" "$FIXTURE_DIR" "$HELPER" || die "fixture generation failed"

note "PASS          bootstrap complete"
note "              DISKTRIAGE_NTFS_PREFIX=$PREFIX"
note "              DISKTRIAGE_FIXTURE_DIR=$FIXTURE_DIR"
note "              next: bash scripts/check.sh"
exit 0
