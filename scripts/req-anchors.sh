#!/bin/sh
# req-anchors.sh — keep a claim's rationale.source on a section, not a line.
#
# A line anchor (`diskdoctor.md#L328`) rots as the plan is edited: the line
# still exists but may enclose a different section. A section anchor
# (`diskdoctor.md#6-cli`) resolves to a heading by GitHub-style slug, so it
# survives edits above it.
#
#   req-anchors.sh --check [--pending FILE]
#       every `<file>#<slug>` rationale.source resolves to a heading in that
#       file, and no `#L<n>` remains — except for the claim ids named in the
#       pending allow-list (one id per line, `#` comments allowed), which are
#       tolerated so another agent can convert them first.
#   req-anchors.sh --fix [--except IDS | --only IDS]
#       rewrite each `#L<n>` source to the slug of the heading that currently
#       encloses line n (the nearest preceding heading; a `###` wins over its
#       `##` because it is nearer). Every other byte of the claim file is
#       preserved. Duplicate heading slugs are disambiguated the GitHub way
#       (`slug`, `slug-1`, `slug-2`).
#
# `--fix` prints `SUSPECT` for every rewritten claim whose statement's key
# words do not appear in the enclosing section's text. That is a heuristic,
# not proof: the plan moved, so a human must eyeball the list before trusting
# a rewrite.
#
# Exit: 0 settled, 1 a definite finding (unresolved slug, a #L outside the
#       pending list, or a #L that cannot be mapped), 3 UNVERIFIABLE (no
#       corpus, or python3 missing), 2 usage.
#
# This script is read-only in --check mode, so scripts/check.sh may call it.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    echo "req-anchors: UNVERIFIABLE cannot resolve the script directory" >&2
    exit 3
}
ROOT="${REQ_ROOT:-$(dirname -- "$SCRIPT_DIR")}"
MODE=""
PENDING="$SCRIPT_DIR/req-anchors.pending"
EXCEPT=""
ONLY=""

usage() {
    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            MODE="check"
            shift
            ;;
        --fix)
            MODE="fix"
            shift
            ;;
        --root)
            [ "$#" -ge 2 ] || { echo "req-anchors: --root needs a directory" >&2; exit 2; }
            ROOT="$2"
            shift 2
            ;;
        --pending)
            [ "$#" -ge 2 ] || { echo "req-anchors: --pending needs a file" >&2; exit 2; }
            PENDING="$2"
            shift 2
            ;;
        --except)
            [ "$#" -ge 2 ] || { echo "req-anchors: --except needs a list of claim ids" >&2; exit 2; }
            EXCEPT="$2"
            shift 2
            ;;
        --except-file)
            [ "$#" -ge 2 ] || { echo "req-anchors: --except-file needs a file" >&2; exit 2; }
            [ -r "$2" ] || { echo "req-anchors: cannot read --except-file $2" >&2; exit 3; }
            EXCEPT="$(tr ',\t ' '\n\n\n' <"$2" | tr -d '\r')"
            shift 2
            ;;
        --only)
            [ "$#" -ge 2 ] || { echo "req-anchors: --only needs a list of claim ids" >&2; exit 2; }
            ONLY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "req-anchors: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$MODE" ] || { echo "req-anchors: one of --check or --fix is required" >&2; exit 2; }

if [ ! -d "$ROOT/claims" ]; then
    echo "req-anchors: UNVERIFIABLE no claims/ under $ROOT" >&2
    exit 3
fi

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "req-anchors: UNVERIFIABLE python3 not found (set PYTHON_BIN)" >&2
    exit 3
fi

exec "$PYTHON_BIN" -I - "$ROOT" "$MODE" "$PENDING" "$EXCEPT" "$ONLY" <<'PY'
import glob
import os
import re
import sys

ROOT, MODE, PENDING, EXCEPT, ONLY = sys.argv[1:6]
CLAIMS_DIR = os.path.join(ROOT, "claims")

HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*$")
SOURCE_RE = re.compile(r"^([ \t]+source:[ \t]*)(.*?)[ \t]*$")
LINE_ANCHOR_RE = re.compile(r"^(.*)#L([0-9]+)$")
STATEMENT_RE = re.compile(r'^statement:[ \t]*"(.*)"[ \t]*$')

STOPWORDS = {
    "about", "above", "after", "again", "against", "always", "among",
    "another", "before", "being", "below", "between", "cannot", "carries",
    "carrying", "claim", "claims", "could", "during", "every", "first",
    "following", "from", "have", "into", "itself", "least", "makes",
    "never", "other", "others", "shall", "should", "since", "still",
    "such", "than", "that", "their", "there", "these", "they", "this",
    "those", "through", "under", "until", "using", "value", "when",
    "where", "which", "while", "with", "within", "without", "would",
    "disktriage", "tool", "must", "only", "does", "each", "same", "moved",
    "moving", "takes", "taken", "given", "gives", "reports", "reported",
}


def unverifiable(message):
    print("req-anchors: UNVERIFIABLE %s" % message, file=sys.stderr)
    raise SystemExit(3)


def github_slug(text):
    """GitHub's heading slug: lower-case, drop punctuation except - and _."""
    slug = text.strip().lower()
    slug = re.sub(r"[^a-z0-9 _-]", "", slug)
    return slug.replace(" ", "-")


def headings(path):
    """Return [(line_number, level, disambiguated_slug, heading_text)]."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError as exc:
        raise SystemExit("req-anchors: cannot read %s: %s" % (path, exc))
    occurrences = {}
    result = []
    for number, line in enumerate(lines, 1):
        match = HEADING_RE.match(line.rstrip("\n"))
        if not match:
            continue
        base = github_slug(match.group(2))
        seen = occurrences.get(base, 0)
        occurrences[base] = seen + 1
        slug = base if seen == 0 else "%s-%d" % (base, seen)
        result.append((number, len(match.group(1)), slug, match.group(2)))
    return lines, result


def load_ids(raw):
    ids = set()
    for token in re.split(r"[,\s]+", raw or ""):
        if re.fullmatch(r"REQ-[0-9]{4}", token):
            ids.add(token)
    return ids


def load_pending(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return load_ids(handle.read())
    except OSError:
        return set()


def claim_sources(text):
    """Yield (line_index, leading, source_value) for rationale.source lines."""
    for index, line in enumerate(text.splitlines(keepends=True)):
        match = SOURCE_RE.match(line.rstrip("\n"))
        if match:
            yield index, match.group(1), match.group(2)


def enclosing(headings_list, line_number):
    chosen = None
    for number, level, slug, _text in headings_list:
        if number <= line_number:
            chosen = (number, level, slug, _text)
        else:
            break
    return chosen


def section_text(lines, headings_list, chosen):
    start, level = chosen[0], chosen[1]
    end = len(lines) + 1
    for number, next_level, _slug, _text in headings_list:
        if number > start and next_level <= level:
            end = number
            break
    return "".join(lines[start - 1:end - 1])


def key_words(statement):
    words = re.findall(r"[A-Za-z]{5,}", statement.lower())
    kept = []
    for word in words:
        if word in STOPWORDS or word in kept:
            continue
        kept.append(word)
    kept.sort(key=lambda word: (-len(word), word))
    return kept[:6]


def suspect_words(statement, section):
    words = key_words(statement)
    if not words:
        return []
    lowered = section.lower()
    missing = [word for word in words if not re.search(r"\b%s" % re.escape(word), lowered)]
    if len(missing) * 2 >= len(words):
        return missing
    return []


def main():
    claim_files = sorted(glob.glob(os.path.join(CLAIMS_DIR, "REQ-*.yml")))
    if not claim_files:
        unverifiable("no claims/REQ-*.yml under %s" % CLAIMS_DIR)

    if MODE == "check":
        pending = load_pending(PENDING)
        findings = []
        allowed = 0
        checked = 0
        for path in claim_files:
            claim_id = os.path.basename(path)[:-4]
            with open(path, encoding="utf-8", newline="") as handle:
                text = handle.read()
            sources = list(claim_sources(text))
            if not sources:
                findings.append("%s: no rationale.source" % claim_id)
                continue
            _index, _leading, source = sources[0]
            checked += 1
            line_match = LINE_ANCHOR_RE.match(source)
            if line_match:
                if claim_id in pending:
                    allowed += 1
                    continue
                findings.append(
                    "%s: line anchor %s (convert it with --fix)" % (claim_id, source)
                )
                continue
            if "#" not in source:
                continue
            target, wanted = source.split("#", 1)
            target_path = os.path.join(ROOT, target)
            if not os.path.isfile(target_path):
                findings.append("%s: source file does not exist: %s" % (claim_id, target))
                continue
            _lines, heading_rows = headings(target_path)
            slugs = {row[2] for row in heading_rows}
            if wanted not in slugs:
                findings.append(
                    "%s: no heading with slug '%s' in %s" % (claim_id, wanted, target)
                )
        if findings:
            for finding in findings:
                print("req-anchors: %s" % finding, file=sys.stderr)
            print(
                "req-anchors: %d finding(s); %d source(s) checked, %d pending"
                % (len(findings), checked, allowed),
                file=sys.stderr,
            )
            return 1
        print(
            "req-anchors: 0 findings; %d source(s) checked, %d pending line anchor(s)"
            % (checked, allowed)
        )
        return 0

    excluded = load_ids(EXCEPT)
    only = load_ids(ONLY)
    changed = 0
    unresolved = []
    suspects = []
    cache = {}

    for path in claim_files:
        claim_id = os.path.basename(path)[:-4]
        if only:
            if claim_id not in only:
                continue
        elif claim_id in excluded:
            continue

        with open(path, encoding="utf-8", newline="") as handle:
            text = handle.read()
        lines = text.splitlines(keepends=True)
        statement = ""
        for line in lines:
            match = STATEMENT_RE.match(line.rstrip("\n"))
            if match:
                statement = match.group(1)
                break

        touched = False
        for index, leading, source in list(claim_sources(text)):
            line_match = LINE_ANCHOR_RE.match(source)
            if not line_match:
                continue
            target, raw_line = line_match.group(1), int(line_match.group(2))
            target_path = os.path.join(ROOT, target)
            if target_path not in cache:
                if not os.path.isfile(target_path):
                    unresolved.append("%s: source file does not exist: %s" % (claim_id, target))
                    cache[target_path] = None
                else:
                    cache[target_path] = headings(target_path)
            entry = cache[target_path]
            if entry is None:
                continue
            target_lines, heading_rows = entry
            if raw_line < 1 or raw_line > len(target_lines):
                unresolved.append(
                    "%s: %s#L%d is past the end of the file" % (claim_id, target, raw_line)
                )
                continue
            chosen = enclosing(heading_rows, raw_line)
            if chosen is None:
                unresolved.append(
                    "%s: %s#L%d is before the first heading" % (claim_id, target, raw_line)
                )
                continue
            slug = chosen[2]
            new_source = "%s#%s" % (target, slug)
            old_line = lines[index]
            ending = "\n" if old_line.endswith("\n") else ""
            lines[index] = "%s%s%s" % (leading, new_source, ending)
            touched = True
            print(
                "FIXED   %s %s#L%d -> %s#%s"
                % (claim_id, target, raw_line, target, slug)
            )
            missing = suspect_words(statement, section_text(target_lines, heading_rows, chosen))
            if missing:
                suspects.append((claim_id, new_source, missing, statement))

        if touched:
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write("".join(lines))
            changed += 1

    for claim_id, source, missing, statement in suspects:
        print(
            "SUSPECT %s -> %s: key word(s) absent from the section: %s"
            % (claim_id, source, ", ".join(missing))
        )
        print("        statement: %s" % statement)

    for problem in unresolved:
        print("req-anchors: %s" % problem, file=sys.stderr)

    print(
        "req-anchors: --fix rewrote %d claim(s); %d suspect(s) for human review"
        % (changed, len(suspects))
    )
    return 1 if unresolved else 0


raise SystemExit(main())
PY
