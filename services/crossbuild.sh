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
# target. Versions come from versions.json exactly as build.sh reads them, and
# the same -X main.Version ldflag is applied, so a cross-built binary reports the
# same version as a native one. Windows targets get a .exe suffix.
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
OUT="$3"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$ROOT/versions.json"
command -v jq >/dev/null || { echo "ERROR: jq is required to read versions.json" >&2; exit 1; }
command -v go >/dev/null || { echo "ERROR: go is required (see docs/building.mdx)" >&2; exit 1; }

SUFFIX=""
[[ "$GOOS_TARGET" == "windows" ]] && SUFFIX=".exe"

COMPONENTS=(
    ollama-proxy lmstudio-proxy nvpair-node-info nvpair-node-scanner
    nvpair-manual-nodes nvpair-workload-manager nvpair-errors
    nvpair-engine-manager nvpair-node-settings nvpair-ui-broker
    nvpair-cluster-manager nvpair-job-scheduler nvpair-tui
)

mkdir -p "$OUT"
echo " Cross-building ${#COMPONENTS[@]} components for $GOOS_TARGET/$GOARCH_TARGET into $OUT"
i=0
for name in "${COMPONENTS[@]}"; do
    i=$((i + 1))
    version=$(jq -r --arg k "$name" '.components[$k]' "$VERSIONS_FILE")
    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "ERROR: no version for $name in versions.json" >&2
        exit 1
    fi
    echo "[$i/${#COMPONENTS[@]}] $name (v$version)"
    (
        cd "$ROOT/$name"
        CGO_ENABLED=0 GOOS="$GOOS_TARGET" GOARCH="$GOARCH_TARGET" \
            go build -trimpath -ldflags "-s -w -X main.Version=$version" -o "$OUT/$name$SUFFIX" .
    )
done
echo " Done: $(ls "$OUT" | wc -l | tr -d ' ') binaries in $OUT"
