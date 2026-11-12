#!/usr/bin/env bash
# Build the hjq executable and copy it to bin/hjq (used by run.sh).
set -euo pipefail
cd "$(dirname "$0")"
cabal build exe:hjq
mkdir -p bin
cp "$(cabal list-bin exe:hjq)" bin/hjq
