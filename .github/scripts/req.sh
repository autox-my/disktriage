#!/usr/bin/env bash
# req.sh — the one place the `req` pin lives.
#
# Sourced by `.github/workflows/ci.yml` and `.github/workflows/release.yml`:
#
#   . .github/scripts/req.sh
#   req_install          # a req built from $REQ_REV on PATH, or the step fails
#
# req is public (github.com/autox-my/req, Apache-2.0) but publishes no prebuilt
# release yet, so a commit is the provenance: `cargo install --git <repo>
# --rev <full sha> --locked` builds it, and `req --version` prints
# `built from <short sha>`. The pin is a full 40-character commit, never a
# branch or a tag that can move.
#
# The trailing `req` in the install command is the package name. The repository
# carries three binaries (req, req-paraphrase, req-tier2), so an install with no
# package selection is ambiguous and cargo refuses it — measured at this rev.
#
# A binary that does not report $REQ_REV is never accepted, so a stale req on
# PATH cannot silently answer for the pinned one. A missing cargo is a failure,
# not a skip: the gate is required (ADR 0029).

REQ_REPO="${REQ_REPO:-https://github.com/autox-my/req.git}"
REQ_REV="${REQ_REV:-f871f80e22807fc8db6c1b9e6ee7b49c45197910}"
REQ_SHORT="${REQ_REV:0:7}"

# req_reports_rev PATH — 0 when the binary says it was built from the pin.
req_reports_rev() {
    [ -x "$1" ] || return 1
    "$1" --version 2>/dev/null | grep -q "built from $REQ_SHORT"
}

# req_ensure_path DIR — put DIR on PATH now and for later workflow steps.
req_ensure_path() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) export PATH="$1:$PATH" ;;
    esac
    if [ -n "${GITHUB_PATH:-}" ]; then
        grep -qxF "$1" "$GITHUB_PATH" 2>/dev/null || printf '%s\n' "$1" >>"$GITHUB_PATH"
    fi
}

# req_install [ROOT] — install req from $REQ_REV unless the one on PATH already
# reports that build. ROOT defaults to $HOME/.cargo, which the workflow caches.
req_install() {
    local root="${1:-$HOME/.cargo}"
    req_ensure_path "$root/bin"

    if command -v req >/dev/null 2>&1 && req_reports_rev "$(command -v req)"; then
        echo "req $(command -v req) already reports $REQ_SHORT"
        return 0
    fi

    command -v cargo >/dev/null 2>&1 || {
        echo "cargo not found; cannot install req $REQ_REV (ADR 0029)" >&2
        return 1
    }

    echo "installing req from $REQ_REPO at $REQ_REV"
    cargo install --git "$REQ_REPO" --rev "$REQ_REV" --locked --root "$root" req || return 1
    req_reports_rev "$root/bin/req" || {
        echo "req at $root/bin/req does not report 'built from $REQ_SHORT'" >&2
        return 1
    }
    req_ensure_path "$root/bin"
    "$root/bin/req" --version
}
