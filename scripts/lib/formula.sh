# shellcheck shell=bash
# formula.sh — render the tap template for a release.
#
# The caller supplies the source url and sha256. `scripts/package.sh formula`
# uses the local `file://` tarball; `scripts/package.sh formula --url <asset>`
# renders the published form that the release workflow attaches. Nothing here
# writes outside the output path it is given, and nothing here talks to the
# network.
#
# Shared with `scripts/check-gate-probe.sh`, which proves the substitution and
# the two rules (url scheme, sha256 shape) without a release build.

# formula_url_ok URL — http(s) only. Homebrew would otherwise try to fetch a
# path or a typo at install time; the formula's url is a release asset.
formula_url_ok() {
    case "$1" in
        https://?* | http://?*) return 0 ;;
        *)
            echo "formula url must start with https:// or http:// (got '$1')" >&2
            return 1
            ;;
    esac
}

# formula_sha256_ok SHA — 64 lowercase hex characters, as `shasum -a 256`
# writes them. An uppercase or truncated digest must never reach a formula.
# Explicit digits, not [0-9a-f]: a bash range follows the locale's collation
# and matches uppercase letters under en_US.UTF-8 (measured on a CI runner).
formula_sha256_ok() {
    case "$1" in
        "" | *[!0123456789abcdef]*)
            echo "formula sha256 must be lowercase hex (got '$1')" >&2
            return 1
            ;;
    esac
    if [ "${#1}" -ne 64 ]; then
        echo "formula sha256 must be 64 characters (got ${#1})" >&2
        return 1
    fi
    return 0
}

# render_formula TEMPLATE OUTPUT URL SHA256
#
# Replaces the template's two placeholders and refuses to leave one behind.
# The template is the checked-in `packaging/homebrew/Formula/disktriage.rb`;
# the output is `dist/disktriage.rb` for a local run, or the release asset.
render_formula() {
    local template="$1" output="$2" url="$3" sha="$4" dir
    [ -f "$template" ] || {
        echo "missing template $template" >&2
        return 1
    }
    formula_url_ok "$url" || return 1
    formula_sha256_ok "$sha" || return 1
    dir="$(dirname "$output")"
    [ -d "$dir" ] || {
        echo "missing output directory $dir" >&2
        return 1
    }
    command -v python3 >/dev/null 2>&1 || {
        echo "python3 is required" >&2
        return 1
    }

    python3 - "$template" "$output" "$url" "$sha" <<'PY'
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
    [ $? -eq 0 ] || {
        echo "cannot render $output" >&2
        return 1
    }
    if grep -q '__DISKTRIAGE_' "$output"; then
        echo "$output still contains a placeholder" >&2
        return 1
    fi
    return 0
}
