#!/bin/bash
# package.sh — local packaging for disktriage without publishing anything.
#
#   scripts/package.sh tarball   git archive HEAD to dist/disktriage-<version>.tar.gz
#                                and write its sha256 beside it.
#   scripts/package.sh formula   write dist/disktriage.rb from the tap template,
#                                substituting the local file:// tarball url and
#                                its sha256.
#   scripts/package.sh verify    ruby -c, brew style/audit, a from-source install
#                                in a temporary tap, the formula test, the otool
#                                no-FUSE check, then uninstall and clean up.
#
# Nothing here pushes, tags, publishes a tap or signs anything: those are the
# human's outward-facing steps (docs/packaging.md). The only network access is
# Homebrew downloading the pinned ntfs-3g tarball, which the formula's sha256
# verifies.
#
# Exit: 0 PASS, 1 FAIL, 3 UNVERIFIABLE (brew/ruby missing, so the end-to-end
#       install could not run).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
    echo "UNVERIFIABLE  cannot resolve the repository root" >&2
    exit 3
}
DIST="$ROOT/dist"
TEMPLATE="$ROOT/packaging/homebrew/Formula/disktriage.rb"
GENERATED="$DIST/disktriage.rb"
TAP="local/disktriage-test"
REPORT="$DIST/verify-report.txt"

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

# Print a line to the terminal and the verify report (when it exists).
note() {
    printf '%s\n' "$*"
    if [ -n "${REPORTING:-}" ]; then
        printf '%s\n' "$*" >>"$REPORT"
    fi
}

die() {
    note "FAIL          $*"
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# One source of truth: ask the built CLI. Only build if the release binary is
# absent, so `tarball` stays cheap after a normal `swift build -c release`.
version() {
    local bin="$ROOT/.build/release/disktriage" out rc
    if [ -x "$bin" ]; then
        out="$("$bin" --version)"
        rc=$?
    else
        out="$(swift run --package-path "$ROOT" -c release disktriage --version)"
        rc=$?
    fi
    [ "$rc" -eq 0 ] || return 1
    case "$out" in
        "disktriage "*) printf '%s\n' "${out#disktriage }" ;;
        *) return 1 ;;
    esac
}

tarball() {
    mkdir -p "$DIST" || die "cannot create $DIST"
    local version tarball sha_file
    version="$(version)" || die "cannot read the version from disktriage --version"
    tarball="$DIST/disktriage-$version.tar.gz"
    sha_file="$tarball.sha256"

    git -C "$ROOT" archive --format=tar.gz \
        --prefix="disktriage-$version/" -o "$tarball" HEAD
    [ $? -eq 0 ] || die "git archive failed"

    shasum -a 256 "$tarball" > "$sha_file.tmp"
    [ $? -eq 0 ] || die "shasum failed for $tarball"
    mv "$sha_file.tmp" "$sha_file"
    local sha
    read -r sha _ < "$sha_file"
    note "PASS          tarball $tarball"
    note "              sha256  $sha"
}

formula() {
    need python3
    local version tarball sha_file sha url
    version="$(version)" || die "cannot read the version from disktriage --version"
    tarball="$DIST/disktriage-$version.tar.gz"
    sha_file="$tarball.sha256"
    if [ ! -f "$tarball" ] || [ ! -f "$sha_file" ]; then
        note "              (tarball absent; generating it first)"
        tarball || exit 1
    fi
    [ -f "$TEMPLATE" ] || die "missing template $TEMPLATE"
    read -r sha _ < "$sha_file"
    url="file://$tarball"

    python3 - "$TEMPLATE" "$GENERATED" "$url" "$sha" <<'PY'
import sys

template, generated, url, sha = sys.argv[1:]
text = open(template, encoding="utf-8").read()
for token, value in (
    ("__DISKTRIAGE_SOURCE_URL__", url),
    ("__DISKTRIAGE_SOURCE_SHA256__", sha),
):
    if token not in text:
        sys.exit(f"template is missing {token}")
    text = text.replace(token, value)
open(generated, "w", encoding="utf-8").write(text)
PY
    [ $? -eq 0 ] || die "cannot render $GENERATED"
    if grep -q '__DISKTRIAGE_' "$GENERATED"; then
        die "$GENERATED still contains a placeholder"
    fi
    note "PASS          formula $GENERATED (url $url)"
}

# Cleanup for verify: only what this run created. The pre-existing
# smartmontools and ddrescue are left alone by construction.
cleanup() {
    if [ "${INSTALLED:-0}" -eq 1 ]; then
        brew uninstall --force disktriage >/dev/null 2>&1 || true
        INSTALLED=0
    fi
    if [ "${TAPPED:-0}" -eq 1 ]; then
        if [ "${TRUSTED:-0}" -eq 1 ]; then
            brew untrust --formula "$TAP/disktriage" >/dev/null 2>&1 || true
            TRUSTED=0
        fi
        brew untap "$TAP" >/dev/null 2>&1 || true
        TAPPED=0
    fi
    if [ "${CLEAN_DEPS:-0}" -eq 1 ]; then
        local current new
        current="$DIST/brew-after-install.txt"
        brew list --formula | sort >"$current" 2>/dev/null
        new="$DIST/brew-new-dependencies.txt"
        if [ -f "$DIST/brew-before.txt" ]; then
            comm -13 "$DIST/brew-before.txt" "$current" | grep -v '^disktriage$' >"$new" || true
            if [ -s "$new" ]; then
                local name
                while IFS= read -r name; do
                    [ -n "$name" ] || continue
                    brew uninstall --force "$name" >/dev/null 2>&1 || \
                        note "WARN          could not remove $name (another formula may need it)"
                done <"$new"
            fi
        fi
        CLEAN_DEPS=0
    fi
}

verify() {
    REPORTING=1
    : >"$REPORT"
    note "== disktriage package verify =="
    note "host: $(sw_vers -productVersion 2>/dev/null || uname -s) $(uname -m)"
    note "brew: $(brew --version 2>/dev/null | head -1)"

    need ruby
    need python3
    need otool

    tarball || exit 1
    formula || exit 1

    ruby -c "$GENERATED" >/dev/null 2>&1
    [ $? -eq 0 ] || die "ruby -c rejected $GENERATED"
    note "PASS          ruby -c"

    if ! command -v brew >/dev/null 2>&1; then
        note "UNVERIFIABLE  brew not found; stopped after ruby -c and the generated formula"
        exit 3
    fi

    # A real user install of disktriage would be destroyed by this script.
    if brew list --formula 2>/dev/null | grep -qx 'disktriage'; then
        die "disktriage is already installed; uninstall it first (this script owns its install)"
    fi

    mkdir -p "$DIST"
    brew list --formula | sort >"$DIST/brew-before.txt"

    if brew tap | grep -qx "$TAP"; then
        die "the temporary tap $TAP already exists; untap it first"
    fi
    brew tap-new --no-git "$TAP" >/dev/null 2>&1
    [ $? -eq 0 ] || die "brew tap-new $TAP failed"
    TAPPED=1
    trap cleanup EXIT
    local taprepo
    taprepo="$(brew --repo "$TAP")"
    mkdir -p "$taprepo/Formula"
    cp "$GENERATED" "$taprepo/Formula/disktriage.rb"

    # Homebrew 7 refuses to load a formula from a non-official tap until it is
    # trusted. This is a temporary local tap, and cleanup removes the entry.
    brew trust --formula "$TAP/disktriage" >/dev/null 2>&1
    [ $? -eq 0 ] || die "brew trust $TAP/disktriage failed"
    TRUSTED=1

    if brew style "$taprepo/Formula/disktriage.rb" >"$DIST/brew-style.txt" 2>&1; then
        note "PASS          brew style"
    else
        note "FAIL          brew style (see $DIST/brew-style.txt)"
        sed 's/^/              /' "$DIST/brew-style.txt" | head -40
        return 1
    fi

    if brew audit --strict --formula "$TAP/disktriage" \
        >"$DIST/brew-audit.txt" 2>&1; then
        note "PASS          brew audit --strict --formula (offline)"
    else
        note "FAIL          brew audit (see $DIST/brew-audit.txt)"
        sed 's/^/              /' "$DIST/brew-audit.txt" | head -40
        return 1
    fi

    brew install --build-from-source "$TAP/disktriage" >"$DIST/brew-install.txt" 2>&1
    [ $? -eq 0 ] || {
        note "FAIL          brew install --build-from-source (see $DIST/brew-install.txt)"
        tail -40 "$DIST/brew-install.txt" | sed 's/^/              /'
        return 1
    }
    INSTALLED=1
    CLEAN_DEPS=1
    note "PASS          brew install --build-from-source $TAP/disktriage"

    local prefix vout vrc check_rc
    prefix="$(brew --prefix disktriage)"
    vout="$("$prefix/bin/disktriage" --version)"
    vrc=$?
    if [ "$vrc" -eq 0 ] && [ "$vout" = "disktriage $(version)" ]; then
        note "PASS          disktriage --version: $vout"
    else
        note "FAIL          disktriage --version: rc=$vrc out=$vout"
        return 1
    fi

    "$prefix/bin/disktriage" check --json >"$DIST/check.json" 2>"$DIST/check.stderr"
    check_rc=$?
    case "$check_rc" in
        0|1|3) note "PASS          disktriage check --json (exit $check_rc; 0/1/3 are the verdict codes)" ;;
        *)
            note "FAIL          disktriage check --json exited $check_rc"
            return 1
            ;;
    esac
    if python3 - "$DIST/check.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
row = next((entry for entry in report.get("checks", []) if entry.get("id") == "ntfs-3g"), None)
if row is None:
    sys.exit("the ntfs-3g row is missing")
if row.get("status") != "PASS":
    sys.exit(f"the ntfs-3g row is {row.get('status')}: {row.get('detail')}")
print(f"ntfs-3g row: {row['status']} — {row['detail']}")
PY
    then
        note "PASS          ntfs-3g is reported found from the keg's libexec"
    else
        note "FAIL          the ntfs-3g row was not PASS (see $DIST/check.json)"
        return 1
    fi

    if brew test "$TAP/disktriage" >"$DIST/brew-test.txt" 2>&1; then
        note "PASS          brew test (version, check --json, no FUSE linkage)"
    else
        note "FAIL          brew test (see $DIST/brew-test.txt)"
        tail -40 "$DIST/brew-test.txt" | sed 's/^/              /'
        return 1
    fi

    local tool linkage_rc=0
    for tool in ntfsinfo ntfsls ntfscat ntfscluster; do
        otool -L "$prefix/libexec/ntfs-3g/bin/$tool" >"$DIST/otool-$tool.txt" 2>&1
        [ $? -eq 0 ] || linkage_rc=1
        if grep -qi 'fuse' "$DIST/otool-$tool.txt"; then
            note "FAIL          $tool links a FUSE library"
            linkage_rc=1
        fi
    done
    otool -L "$prefix/bin/disktriage" >"$DIST/otool-disktriage.txt" 2>&1
    [ $? -eq 0 ] || linkage_rc=1
    grep -qi 'fuse' "$DIST/otool-disktriage.txt" && linkage_rc=1
    if [ "$linkage_rc" -eq 0 ]; then
        note "PASS          otool: disktriage and the four ntfs tools link no FUSE library"
    else
        note "FAIL          otool found a FUSE reference"
        return 1
    fi

    cleanup
    trap - EXIT

    brew list --formula | sort >"$DIST/brew-after.txt"
    local diff
    diff="$(comm -3 "$DIST/brew-before.txt" "$DIST/brew-after.txt")"
    if [ -z "$diff" ]; then
        note "PASS          brew list is unchanged after uninstall (before/after in dist/)"
    else
        note "WARN          brew list changed:"
        printf '%s\n' "$diff" | sed 's/^/              /'
    fi
    note "PASS          no push, no tag, no tap publication, no signing"
    note "RESULT        PASS"
    return 0
}

case "${1:-}" in
    tarball) tarball ;;
    formula) formula ;;
    verify) verify ;;
    -h|--help|help|"") usage ;;
    *) echo "package.sh: unknown subcommand '$1'" >&2; usage >&2; exit 2 ;;
esac
