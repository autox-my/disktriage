#!/bin/sh
# req-counts.sh — generate the requirement counts in docs/req-workflow.md.
#
# The counts live in one block between the markers
#
#     <!-- req-counts:begin -->
#     <!-- req-counts:end -->
#
# and are derived from the corpus, never typed:
#
#   - total claims           claims/REQ-*.yml
#   - pins held              req gate --format json, pins_hold.checked
#   - linked to tests        a non-empty top-level tests: list
#   - process-evidenced      evidence: process
#   - unlinked               neither tests nor process evidence
#
#   req-counts.sh [--root DIR] --write   rewrite the block
#   req-counts.sh [--root DIR] --check   0 current, 1 stale block
#
# Exit: 0 settled, 1 a definite finding (a stale or missing block), 3
#       UNVERIFIABLE (req or claims/ missing, or a gate document that cannot
#       be read), 2 usage.
#
# After a merge that changes the corpus, run `scripts/req-counts.sh --write`;
# that single command is the human's final step before the gate.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    echo "req-counts: UNVERIFIABLE cannot resolve the script directory" >&2
    exit 3
}
ROOT="${REQ_ROOT:-$(dirname -- "$SCRIPT_DIR")}"
MODE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --write)
            MODE="write"
            shift
            ;;
        --check)
            MODE="check"
            shift
            ;;
        --root)
            [ "$#" -ge 2 ] || { echo "req-counts: --root needs a directory" >&2; exit 2; }
            ROOT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "req-counts: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$MODE" ] || { echo "req-counts: one of --write or --check is required" >&2; exit 2; }

if [ ! -d "$ROOT/claims" ]; then
    echo "req-counts: UNVERIFIABLE no claims/ under $ROOT" >&2
    exit 3
fi

REQ_BIN="${REQ_BIN:-$(command -v req 2>/dev/null || true)}"
if [ -z "$REQ_BIN" ] || [ ! -x "$REQ_BIN" ]; then
    echo "req-counts: UNVERIFIABLE req not found (set REQ_BIN)" >&2
    exit 3
fi

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "req-counts: UNVERIFIABLE python3 not found (set PYTHON_BIN)" >&2
    exit 3
fi

TMP="$(mktemp -d)" || {
    echo "req-counts: UNVERIFIABLE cannot create a temporary directory" >&2
    exit 3
}
trap 'rm -rf "$TMP"' EXIT

GATE_JSON="$TMP/gate.json"
"$REQ_BIN" --root "$ROOT" gate --format json >"$GATE_JSON" 2>"$TMP/gate.err"
# Exit 3 is expected while claims are unlinked; the document is still the
# evidence for pins_hold.checked. An absent or unparsable document is 3.

exec "$PYTHON_BIN" -I - "$ROOT" "$MODE" "$GATE_JSON" <<'PY'
import glob
import json
import os
import re
import sys

ROOT, MODE, GATE_JSON = sys.argv[1:4]
CLAIMS_DIR = os.path.join(ROOT, "claims")
DOC = os.path.join(ROOT, "docs", "req-workflow.md")
BEGIN = "<!-- req-counts:begin -->"
END = "<!-- req-counts:end -->"


def unverifiable(message):
    print("req-counts: UNVERIFIABLE %s" % message, file=sys.stderr)
    raise SystemExit(3)


def finding(message):
    print("req-counts: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def claim_ids():
    paths = sorted(glob.glob(os.path.join(CLAIMS_DIR, "REQ-*.yml")))
    if not paths:
        unverifiable("no claims/REQ-*.yml under %s" % CLAIMS_DIR)
    return paths


def has_tests(text):
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("tests:"):
            start = index
            break
    if start is None:
        return False
    inline = lines[start][len("tests:"):].strip()
    if inline and inline != "[]":
        return True
    for line in lines[start + 1:]:
        if line[:1] not in (" ", "\t"):
            break
        if re.match(r"^[ \t]*-[ \t]*\S", line):
            return True
    return False


def has_process_evidence(text):
    for line in text.splitlines():
        match = re.match(r"^evidence:[ \t]*(.*?)[ \t]*$", line)
        if match:
            value = match.group(1).strip().strip("'\"")
            if value == "process":
                return True
    return False


def pins_held(path):
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as exc:
        unverifiable("cannot read the gate document %s: %s" % (path, exc))
    for policy in document.get("policies", []):
        if policy.get("policy") == "pins_hold":
            checked = policy.get("checked")
            if not isinstance(checked, int):
                unverifiable("the gate document has no pins_hold.checked count")
            return checked
    unverifiable("the gate document has no pins_hold policy")


def block(total, pins, linked, process, unlinked):
    lines = [
        BEGIN,
        "- %d claims total." % total,
        "- %d pins held (`req gate --format json`, `pins_hold.checked`)." % pins,
        "- %d claims have a non-empty `tests:` list." % linked,
        "- %d claims are process-evidenced (`evidence: process`)." % process,
        "- %d claims are unlinked: no linked test and no process evidence." % unlinked,
        END,
    ]
    return "\n".join(lines)


def read_doc():
    try:
        with open(DOC, encoding="utf-8", newline="") as handle:
            return handle.read()
    except OSError as exc:
        unverifiable("cannot read %s: %s" % (DOC, exc))


def replace_block(text, new_block):
    if BEGIN not in text or END not in text:
        finding("%s has no req-counts markers; add %s and %s" % (DOC, BEGIN, END))
    start = text.index(BEGIN)
    end = text.index(END, start) + len(END)
    return text[:start] + new_block + text[end:]


def main():
    total = 0
    linked = 0
    process = 0
    unlinked = 0
    for path in claim_ids():
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        total += 1
        has_link = has_tests(text)
        has_process = has_process_evidence(text)
        if has_link:
            linked += 1
        if has_process:
            process += 1
        if not has_link and not has_process:
            unlinked += 1
    pins = pins_held(GATE_JSON)
    new_block = block(total, pins, linked, process, unlinked)
    current = read_doc()

    if MODE == "write":
        updated = replace_block(current, new_block)
        if updated != current:
            with open(DOC, "w", encoding="utf-8", newline="") as handle:
                handle.write(updated)
            print("req-counts: wrote the block in %s" % DOC)
        else:
            print("req-counts: the block is already current")
        return 0

    if BEGIN not in current or END not in current:
        finding("%s has no req-counts markers" % DOC)
    start = current.index(BEGIN)
    end = current.index(END, start) + len(END)
    if current[start:end] != new_block:
        finding(
            "the req-counts block is stale; run scripts/req-counts.sh --write (%d claims, %d pins, %d linked, %d process, %d unlinked)"
            % (total, pins, linked, process, unlinked)
        )
    print(
        "req-counts: current (%d claims, %d pins held, %d linked, %d process, %d unlinked)"
        % (total, pins, linked, process, unlinked)
    )
    return 0


raise SystemExit(main())
PY
