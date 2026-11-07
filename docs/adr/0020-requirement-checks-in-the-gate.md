# 0020. Requirement checks run in the gate (v3.9 follow-up)

Status: accepted
Date: 2026-11-07

## Context

The gate used to judge only the suite. The requirement corpus is now part of
the same verdict: `scripts/check.sh` runs read-only requirement steps after
`swift test` writes its JUnit report.

## Decision

The gate now judges the corpus as well as the suite. After `swift test` writes
`.build/test-results/junit-swift-testing.xml`, `scripts/check.sh` runs five
read-only requirement steps and folds them with the test step:

| Step | 0 | 1 | 3 |
|---|---|---|---|
| `req canon --fail-on-flag` | no flagged pin | a flagged pin | — (a missing `req` is 3) |
| `scripts/req-link.sh --check` | lists match the report | drift | no usable report |
| `req gate --test-report <report>` | every claim decided | a failed linked test or a flagged pin | a claim has no linked test, or a link is stale |
| `scripts/req-anchors.sh --check` | every source resolves to a heading | an unresolved slug or an unallowed `#L` | no corpus |
| `scripts/req-counts.sh --check` | the docs block is current | the block is stale | `req` or `claims/` missing |

Precedence is unchanged: any **1** is FAIL, even beside a **3**; otherwise a
**3** is UNVERIFIABLE and the last line names every step that did not pass. On
this branch every step passes except `req gate`, which is 3 because the 40
unlinked claims have no linked test; that is reported, not hidden or turned
into a pass. A missing `req` binary is 3, never a skip to 0.

`scripts/req-anchors.sh` replaces line anchors (`diskdoctor.md#L328`) with
GitHub-style section slugs (`diskdoctor.md#6-cli`) so the source survives edits
above it. `--fix` prints `SUSPECT` for a rewritten claim whose statement's key
words do not appear in the enclosing section; a human must eyeball that list,
because the plan moved and the line may have pointed into the wrong section
before the rewrite. `scripts/req-anchors.pending` is the explicit allow-list
for the 40 claims being triaged elsewhere: it is deleted after the final
`scripts/req-anchors.sh --fix`, and every other `#L` anchor fails the step.

`scripts/req-counts.sh --write` regenerates the counts block in
`docs/req-workflow.md` from the corpus itself (claims, pins held, linked,
process-evidenced, unlinked). After a merge that changes `claims/`, that one
command is the human's final step before the gate.

## Consequences

- This supersedes the earlier TDD-loop note that `req-link.sh` is advisory: only
  its read-only `--check` mode is in the gate, and the write mode that edits the
  corpus is still outside it.

## Requirements

None. No claim's `rationale.source` points at this record.
