# 0031. Bundle identifier `my.autox.disktriage`

Status: accepted
Date: 2026-11-09

## Context

macOS keys a Full Disk Access (TCC) grant to a program's signed identity. The
plan (§7, *Process identity*) says a signed `.app` or helper keeps its grant
across updates only if its `CFBundleIdentifier` and signature stay stable; an
ad-hoc build is keyed by path and hash and loses the grant on every rebuild.
The identifier is therefore effectively permanent once users have granted
access: changing it orphans every grant.

The identifier was left open until the project name settled (plan §12). The
name is now `disktriage` (renamed 2026-11-06), the repository is public under
the `autox-my` GitHub organisation, and the CLI is released and installable
through the Homebrew tap.

## Decision

The bundle identifier for any signed `disktriage` bundle (the `.app` launcher
of option B, or the helper of option C) is **`my.autox.disktriage`**.

- Helpers owned by the same product use it as a prefix, for example
  `my.autox.disktriage.helper`.
- The identifier is chosen now, before any signed build, so the first signed
  build is also the first one users grant access to.
- Nothing is built or signed by this decision. The Homebrew CLI has no bundle
  and is unaffected. The plan's default stays option A (the CLI run from
  Terminal); options B and C remain gated on the open P0 test of whether a
  child of the signed `.app` inherits the grant, and on a Developer ID
  (P4, human-only).

## Consequences

- P4 is no longer blocked on this name; it is still blocked on a paid Apple
  Developer Program membership, notarization and the P0 child-inheritance
  test.
- Changing the identifier later is a new ADR that must say how existing grants
  are migrated. It does not rewrite this one.
- The decision is a repository fact, not runtime behaviour, so it has no Swift
  test and no `req` claim.
