#!/bin/sh
# req-link.sh — make a claim's `tests:` list follow the JUnit report.
#
# A test is linked to a claim by a REQ tag in the test FUNCTION name, because
# Swift Testing's @Test display name never reaches the JUnit report:
#
#   func REQ0038_precedencePicksTheMostSevere()
#     -> <testcase classname="DiskTriageCoreTests.ExitCodeTests"
#                   name="REQ0038_precedencePicksTheMostSevere()" />
#     -> id "DiskTriageCoreTests.ExitCodeTests::REQ0038_precedencePicksTheMostSevere()"
#
# The script reads every *.xml under .build/test-results/, extracts each
# REQ-NNNN tag (written REQNNNN in code) from each testcase name, and rewrites
# ONLY the top-level `tests:` list of the matching claims/REQ-NNNN.yml, sorted,
# de-duplicated, in the exact id form above. Every other byte is preserved.
#
#   req-link.sh [--root DIR]           write the lists (idempotent)
#   req-link.sh [--root DIR] --check   exit 0 if claims match, 1 if they drift
#
# Exit: 0 settled, 1 a definite finding (drift, or a tag naming no claim),
#       3 UNVERIFIABLE (report missing, empty, unparsable, or no corpus),
#       2 usage. A missing report is never a pass. A tag naming a claim that
#       does not exist fails loudly and writes nothing.
#
# `--check` is read-only, so scripts/check.sh calls it as a gate step. The
# default (write) mode edits the corpus and is deliberately not in the gate:
# the gate never rewrites a claim.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    echo "req-link: UNVERIFIABLE cannot resolve the script directory" >&2
    exit 3
}
ROOT="${REQ_ROOT:-$(dirname -- "$SCRIPT_DIR")}"
MODE="write"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            [ "$#" -ge 2 ] || { echo "req-link: --root needs a directory" >&2; exit 2; }
            ROOT="$2"
            shift 2
            ;;
        --check)
            MODE="check"
            shift
            ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "req-link: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$ROOT/claims" ]; then
    echo "req-link: UNVERIFIABLE no claims/ under $ROOT" >&2
    exit 3
fi

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "req-link: UNVERIFIABLE python3 not found (set PYTHON_BIN)" >&2
    exit 3
fi

exec "$PYTHON_BIN" -I - "$ROOT" "$MODE" <<'PY'
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT, MODE = sys.argv[1], sys.argv[2]
REPORT_DIR = os.path.join(ROOT, ".build", "test-results")
CLAIMS_DIR = os.path.join(ROOT, "claims")
TAG_RE = re.compile(r"REQ-?(\d{4})(?!\d)")
ID_LINE_RE = re.compile(r'^[ \t]*-[ \t]*(.*?)[ \t]*$')


def unverifiable(message):
    print("req-link: UNVERIFIABLE %s" % message, file=sys.stderr)
    raise SystemExit(3)


def finding(message):
    print("req-link: %s" % message, file=sys.stderr)
    raise SystemExit(1)


def load_report():
    files = sorted(glob.glob(os.path.join(REPORT_DIR, "*.xml")))
    if not files:
        unverifiable("no JUnit report under %s" % REPORT_DIR)
    found = {}
    total = 0
    for path in files:
        try:
            tree = ET.parse(path)
        except (ET.ParseError, OSError) as exc:
            unverifiable("cannot parse %s: %s" % (path, exc))
        for case in tree.getroot().iter("testcase"):
            total += 1
            classname = case.get("classname") or ""
            name = case.get("name") or ""
            if not classname or not name:
                unverifiable("%s has a testcase without classname/name" % path)
            ident = "%s::%s" % (classname, name)
            for digits in TAG_RE.findall(name):
                found.setdefault("REQ-%s" % digits, set()).add(ident)
    if total == 0:
        unverifiable("the report carries no test cases (%s)" % ", ".join(files))
    return found, len(files)


def read_tests(text):
    """Return (values, start, end) for the top-level tests: block, or None."""
    lines = text.splitlines(keepends=True)
    start = None
    for index, line in enumerate(lines):
        if line.startswith("tests:"):
            start = index
            break
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and lines[end][:1] in (" ", "\t"):
        end += 1
    inline = lines[start][len("tests:"):].strip()
    values = []
    if inline:
        if inline == "[]":
            pass
        else:
            finding(
                "%s: cannot read an inline tests: list; write it as a block list"
                % os.path.join(CLAIMS_DIR, "?")
            )
    for line in lines[start + 1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = ID_LINE_RE.match(line.rstrip("\n"))
        if not match:
            finding("cannot read a tests: list item: %r" % line.rstrip("\n"))
        value = match.group(1)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if value:
            values.append(value)
    return values, start, end


def yaml_quote(value):
    return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')


def render(text, desired):
    block = "".join(
        "tests:\n" + "".join("  - %s\n" % yaml_quote(i) for i in desired)
        if desired
        else ""
    )
    existing = read_tests(text)
    if existing is None:
        if not desired:
            return text
        if text and not text.endswith("\n"):
            text += "\n"
        return text + block
    _, start, end = existing
    lines = text.splitlines(keepends=True)
    return "".join(lines[:start]) + block + "".join(lines[end:])


def claim_path(claim_id):
    return os.path.join(CLAIMS_DIR, "%s.yml" % claim_id)


def main():
    desired, report_count = load_report()

    missing = [c for c in sorted(desired) if not os.path.isfile(claim_path(c))]
    if missing:
        for claim in missing:
            print(
                "req-link: tag names a claim that does not exist: %s (claims/%s.yml)"
                % (claim, claim),
                file=sys.stderr,
            )
        print("req-link: nothing was written", file=sys.stderr)
        return 1

    claim_files = sorted(glob.glob(os.path.join(CLAIMS_DIR, "*.yml")))
    drift = []
    pending = {}
    for path in claim_files:
        claim_id = os.path.basename(path)[:-4]
        if not re.fullmatch(r"REQ-\d{4}", claim_id):
            continue
        with open(path, encoding="utf-8", newline="") as handle:
            text = handle.read()
        existing = read_tests(text)
        current = [] if existing is None else existing[0]
        wanted = sorted(desired.get(claim_id, set()))
        if current != wanted:
            drift.append((claim_id, current, wanted))
            new_text = render(text, wanted)
            if new_text != text:
                pending[path] = new_text

    if MODE == "check":
        if not drift:
            print(
                "req-link: 0 drift; claims match %d report file(s)" % report_count
            )
            return 0
        for claim_id, current, wanted in drift:
            print("req-link: %s drifts" % claim_id, file=sys.stderr)
            for ident in sorted(set(current) - set(wanted)):
                print("  stale:    %s" % ident, file=sys.stderr)
            for ident in sorted(set(wanted) - set(current)):
                print("  missing:  %s" % ident, file=sys.stderr)
            if sorted(current) != sorted(set(current)):
                print("  unsorted or duplicated tests: list", file=sys.stderr)
        return 1

    for path, new_text in pending.items():
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(new_text)
    for claim_id, current, wanted in drift:
        print(
            "req-link: %s %d -> %d id(s)"
            % (claim_id, len(current), len(wanted))
        )
    if not pending:
        print("req-link: 0 changes; claims already match the report")
    return 0


raise SystemExit(main())
PY
