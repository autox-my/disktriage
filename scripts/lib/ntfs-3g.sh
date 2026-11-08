# shellcheck shell=bash
# The pinned ntfs-3g build recipe, shared by scripts/bootstrap.sh and the
# Homebrew formula's resource block. Keep the version and sha256 in step with
# packaging/homebrew/Formula/disktriage.rb; scripts/check.sh's sibling probe
# checks the pin, and the formula's sha256 is the same value.
#
# Only the userspace tools are built: --disable-ntfs-3g turns the FUSE driver
# off, so configure never looks for libfuse, and --disable-shared --enable-static
# keeps the prefix relocatable. --exec-prefix must match --prefix or install
# writes to /lib. ac_cv_header_libintl_h=no keeps Homebrew's gettext header from
# making the static link want libintl (the formula uses the same cache variable).

NTFS3G_VERSION="2026.9.28"
NTFS3G_TARBALL="ntfs-3g_ntfsprogs-${NTFS3G_VERSION}.tgz"
NTFS3G_URL="https://download.tuxera.com/opensource/${NTFS3G_TARBALL}"
NTFS3G_SHA256="350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8"

# The one configure line. Echoed by the bootstrap's --print-recipe mode and
# used verbatim by ntfs3g_build.
ntfs3g_configure_flags() {
    local prefix="$1"
    printf '%s\n' \
        "ac_cv_header_libintl_h=no" \
        "--prefix=$prefix" \
        "--exec-prefix=$prefix" \
        "--disable-ntfs-3g" \
        "--disable-shared" \
        "--enable-static" \
        "--disable-ldconfig" \
        "--disable-mtab" \
        "--disable-mount-helper"
}

ntfs3g_sha256() {
    local file="$1" out
    out="$(shasum -a 256 "$file" 2>/dev/null)" || return 1
    printf '%s\n' "${out%% *}"
}

# A prefix built by this recipe is complete when the marker names the pinned
# version and the tools the live tests need are executable.
ntfs3g_prefix_is_built() {
    local prefix="$1"
    [ -n "$prefix" ] || return 1
    [ -f "$prefix/.ntfs-3g-version" ] || return 1
    [ "$(cat "$prefix/.ntfs-3g-version" 2>/dev/null)" = "$NTFS3G_VERSION" ] || return 1
    [ -x "$prefix/bin/ntfsinfo" ] || return 1
    [ -x "$prefix/bin/ntfsls" ] || return 1
    [ -x "$prefix/sbin/mkntfs" ] || return 1
    return 0
}

# ntfs3g_build <prefix> <cache-dir> <build-dir> [jobs]
#
# Downloads the pinned tarball only when the cache is empty, verifies its
# sha256 on every run, extracts into the build directory and installs the
# userspace tools. Idempotent: a complete prefix returns 0 without doing work.
ntfs3g_build() {
    local prefix="$1" cache="$2" build="$3" jobs="${4:-4}"
    if ntfs3g_prefix_is_built "$prefix"; then
        return 0
    fi

    mkdir -p "$cache" "$build" || return 1
    local tarball="$cache/$NTFS3G_TARBALL"
    if [ ! -f "$tarball" ]; then
        # Download to a temporary name so an interrupted transfer never looks
        # like a cache hit.
        curl -fSL --retry 3 -o "$tarball.part" "$NTFS3G_URL" || return 1
        mv "$tarball.part" "$tarball" || return 1
    fi

    local actual
    actual="$(ntfs3g_sha256 "$tarball")" || return 1
    if [ "$actual" != "$NTFS3G_SHA256" ]; then
        echo "sha256 mismatch for $tarball" >&2
        echo "  expected $NTFS3G_SHA256" >&2
        echo "  actual   $actual" >&2
        return 1
    fi

    rm -rf "$build/src" || return 1
    mkdir -p "$build/src" || return 1
    tar -xzf "$tarball" -C "$build/src" --strip-components=1 || return 1

    local flags=()
    while IFS= read -r flag; do flags+=("$flag"); done < <(ntfs3g_configure_flags "$prefix")

    (
        cd "$build/src" || exit 1
        ./configure "${flags[@]}" >"$build/configure.log" 2>&1 || exit 1
        make -j"$jobs" >"$build/make.log" 2>&1 || exit 1
        make install >"$build/install.log" 2>&1 || exit 1
    ) || return 1

    printf '%s\n' "$NTFS3G_VERSION" >"$prefix/.ntfs-3g-version" || return 1
    return 0
}
