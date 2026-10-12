#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# crossbuild.sh — build the thirteen service binaries for another OS/arch.
#
#   ./crossbuild.sh <goos> <goarch> <outdir>
#   ./crossbuild.sh linux arm64 /tmp/pair-linux-arm64/bin
#
# Every module is pure Go (no cgo), so any host can build for any supported
# target. Versions come from versions.json and desktop/package.json exactly as
# build.sh reads them, and the same ldflags are applied, so a cross-built binary
# reports the same versions as a native one. Windows targets get a .exe suffix.
#
# The set mirrors build.sh: twelve components from versions.json plus
# inference-dispatcher, which lives at scripts/inference-dispatcher and is
# stamped with the services version.
#
# build.sh remains the native build for local development; this script exists
# for release bundles and for staging a headless machine from another host.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <goos> <goarch> <outdir>" >&2
    exit 2
fi
GOOS_TARGET="$1"
GOARCH_TARGET="$2"
# Resolve the output directory to an absolute path first: each go build runs
# from its component directory, where a relative path would land elsewhere.
mkdir -p "$3"
OUT="$(cd "$3" && pwd)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$ROOT/versions.json"
command -v jq >/dev/null || { echo "ERROR: jq is required to read versions.json" >&2; exit 1; }
command -v go >/dev/null || { echo "ERROR: go is required (see docs/building.mdx)" >&2; exit 1; }

SUFFIX=""
[[ "$GOOS_TARGET" == "windows" ]] && SUFFIX=".exe"

V_SERVICES=$(jq -r '.services' "$VERSIONS_FILE")
V_RELEASE=$(jq -r '.version' "$ROOT/../desktop/package.json" 2>/dev/null)
for v in "$V_SERVICES" "$V_RELEASE"; do
    if [[ -z "$v" || "$v" == "null" ]]; then
        echo "ERROR: could not read the services version (versions.json) or the release version (desktop/package.json)" >&2
        exit 1
    fi
done

COMPONENTS=(
    nvpair-proxy nvpair-node-info nvpair-node-scanner
    nvpair-manual-nodes nvpair-workload-manager nvpair-errors
    nvpair-engine-manager nvpair-node-settings nvpair-ui-broker
    nvpair-cluster-manager nvpair-job-scheduler nvpair-tui
)
DISPATCHER_SRC="$ROOT/../scripts/inference-dispatcher"
TOTAL=$(( ${#COMPONENTS[@]} + 1 ))

gobuild() {
    local out="$1" ldflags="$2"
    CGO_ENABLED=0 GOOS="$GOOS_TARGET" GOARCH="$GOARCH_TARGET" \
        go build -trimpath -ldflags "-s -w $ldflags" -o "$out" .
}

mkdir -p "$OUT"
# Start from an empty set, like build.sh: a binary left by an older revision
# would otherwise ride into the bundle and be counted below.
find "$OUT" -maxdepth 1 -type f -delete
echo " Cross-building $TOTAL binaries for $GOOS_TARGET/$GOARCH_TARGET into $OUT"
i=0
for name in "${COMPONENTS[@]}"; do
    i=$((i + 1))
    version=$(jq -r --arg k "$name" '.components[$k]' "$VERSIONS_FILE")
    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "ERROR: no version for $name in versions.json" >&2
        exit 1
    fi
    ldflags="-X main.Version=$version"
    # nvpair-tui's update notice compares the release version, not its own
    # component version, against the published tag (see build.sh).
    [[ "$name" == "nvpair-tui" ]] && ldflags="$ldflags -X nvpair-tui/ui.ReleaseVersion=$V_RELEASE"
    echo "[$i/$TOTAL] $name (v$version)"
    (cd "$ROOT/$name" && gobuild "$OUT/$name$SUFFIX" "$ldflags")
done
echo "[$TOTAL/$TOTAL] inference-dispatcher (v$V_SERVICES)"
[[ -d "$DISPATCHER_SRC" ]] || { echo "ERROR: $DISPATCHER_SRC not found" >&2; exit 1; }
(cd "$DISPATCHER_SRC" && gobuild "$OUT/inference-dispatcher$SUFFIX" "-X main.Version=$V_SERVICES")

built=$(find "$OUT" -maxdepth 1 -type f | wc -l | tr -d ' ')
if [[ "$built" -ne $TOTAL ]]; then
    echo "ERROR: expected $TOTAL binaries in $OUT, found $built" >&2
    exit 1
fi
echo " Done: $built binaries in $OUT"
