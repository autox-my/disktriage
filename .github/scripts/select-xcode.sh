#!/usr/bin/env bash
# Prints the /Applications/Xcode*.app to use, chosen from what the runner
# actually has. No path or version is hard-coded: a runner-image refresh that
# adds or removes an Xcode must not need a workflow edit.
#
#   select-xcode.sh stable   newest installed *stable* Xcode (a name carrying
#                            beta / RC / Release_Candidate is skipped)
#   select-xcode.sh newest   newest installed Xcode, previews included (used by
#                            the informational preview job)
#
# XCODE_APP_DIR overrides /Applications so the selection can be exercised
# against fake bundles without an Xcode install.
#
# Exits 1 with a message when nothing suitable is installed, so the caller
# fails with a reason instead of silently building with the image default.
set -uo pipefail

app_dir="${XCODE_APP_DIR:-/Applications}"

mode="${1:-stable}"
case "$mode" in
    stable | newest) ;;
    *)
        echo "usage: select-xcode.sh [stable|newest]" >&2
        exit 2
        ;;
esac

best_version=""
best_path=""

for app in "$app_dir"/Xcode*.app; do
    [ -d "$app" ] || continue

    name="$(basename "$app" .app)"
    # The unversioned alias points at the image default, so it is never the
    # answer: the point is to choose from the installed set.
    [ "$name" = "Xcode" ] && continue

    if [ "$mode" = "stable" ]; then
        case "$name" in
            *[Bb]eta* | *RC* | *[Rr]elease_Candidate*) continue ;;
        esac
    fi

    plist="$app/Contents/Info.plist"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)" || continue
    [ -n "$version" ] || continue
    [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] || continue

    if [ -z "$best_version" ]; then
        best_version="$version"
        best_path="$app"
        continue
    fi

    # `sort -V` gives 26.10 > 26.9 and 27.0 > 26.6 without parsing versions by
    # hand. Equal versions keep the first candidate.
    newest="$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1)"
    if [ "$newest" != "$best_version" ]; then
        best_version="$version"
        best_path="$app"
    fi
done

if [ -z "$best_path" ]; then
    echo "no $mode Xcode found under $app_dir (mode: $mode)" >&2
    exit 1
fi

printf '%s\n' "$best_path"
