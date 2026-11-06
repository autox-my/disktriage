#!/bin/sh
# Builds the DiskArbitration mount-dissent probe: captures/dadissent (Mach-O), ad-hoc signed.
# Does not run it and does not touch any disk. Runbook A5/B3.
set -e
cd "$(dirname "$0")/../.."
mkdir -p captures
swiftc -swift-version 6 -O -framework DiskArbitration -framework CoreFoundation \
    tools/p0/dadissent.swift -o captures/dadissent
codesign --force --sign - captures/dadissent
echo "built captures/dadissent"
