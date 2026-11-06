# claims/ — this project's requirement corpus

One claim per file, in the req claim-file format (`req.claim/2`). The file name is the
`claim_id` it declares (`REQ-0001.yml`), the corpus is flat, and this README is not a claim
(it is not claim-shaped, so the loader leaves it alone).

A claim is **authored**: `statement`, `applicability`, `relations`, `rationale`, and optionally
`tests`, `evidence` and `pins`. Its parse — modality, subject, comparator, value, unit,
conditions — is **derived** from `statement` every time the claim is loaded, and so are its
canonical form and its address. Nothing derived is stored in the file, so there is nothing to
fill and nothing to hand-write. `pins:` states what the parse must be where it is load-bearing
(`operator: LE`, `value: "0.2"`, `unit: s`); a pin the parse does not hold is a flag, never a
silent note.

A `spec.md`, a backlog or a capabilities table can seed this corpus instead of transcribing it:
copy `tools/adopt.py` from req's repository, adjust its mapping to your document, and run it from
this corpus's root with `python3 tools/adopt.py --from <doc> --date YYYY-MM-DD` first — a dry
run that writes nothing and names every draft and every skipped line. (`--date` is required when
the document is untracked or changed since its last commit; the tool never invents one.) Then add
`--write` to draft one claim per candidate — a markdown list item (the default `bullets`
convention) or, with `--convention req-lines`, a `- REQ-<n>:` line. A draft carries the statement
and its provenance and nothing derived; add `pins:` where the parse is load-bearing.

## The authoring loop

1. Edit `statement` (and `applicability`, which is part of the address too). The starter claim's
   `pins:` state the bound of its sample statement: change them with the statement, or delete
   them, or `req gate` fails `pins_hold` on a pin you no longer mean.
2. Run `req canon`. It prints the parse the statement derives and each pin's verdict. It reports
   and by default never gates: a flagged pin does not fail it unless you pass `--fail-on-flag` (it exits 3 only when the corpus cannot be read).
3. Run `req gate` before you ship; the CI section of req's `docs/adopting.md` wires it. A pin
   that does not hold fails `pins_hold` (exit 1).

## The traps

- **A pin that disagrees with the parse is a flag, and the gate fails on it.** Re-word the
  statement, or correct the pin — never write the prose to fit the parse.
- **Values are canonical SI.** `within 200 ms` parses to `value "0.2"`, `unit s`: pin the exact
  decimal string the parser derives. `unit: ms` is a contradiction, and `"0.30"` is not a
  canonical decimal (`"0.3"` is), so it cannot be pinned at all.
- **An empty `claims/` is UNVERIFIABLE, not a pass.** Zero claims cannot be told from every
  claim having vanished, so `req canon` and `req gate` exit 3. Never "clean up" to zero claims —
  delete a requirement by deleting its claim deliberately, in a commit that says so.
- **One obligation per claim.** A statement carrying a second modal (`shall … and shall
  not …`) is two claims; split it.
- **`applicability:` makes a claim variant-scoped.** Declare every variant (one `key=value ...`
  release per line in `.req/variants`; `req check` gates each one): a claim a release leaves
  undecided is not examined, so its gate exits 3 and names it — the invocation that decides
  every claim is the gate (ADR 0015).
- **A `req.claim/1` file is NOT JUDGED.** Migrate it with `tools/migrate_claims.py` from req's
  repository (a dry run by default; `--write` rewrites it).
