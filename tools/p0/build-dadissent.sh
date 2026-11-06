#!/bin/sh
# Builds the DiskArbitration mount-dissent probe: captures/dadissent (Mach-O),
# ad-hoc signed. Does not run it and does not touch any disk. Runbook A5/B3.
#
# The session, the callback and the pure decision now live in
# Sources/DiskTriageGuard, shared with `disktriage guard`; this script builds
# the thin Sources/dadissent entry point from that target instead of a second
# copy of the logic.
set -e
cd "$(dirname "$0")/../.."
mkdir -p captures
swift build -c release --product dadissent
cp .build/release/dadissent captures/dadissent
codesign --force --sign - captures/dadissent
echo "built captures/dadissent"
