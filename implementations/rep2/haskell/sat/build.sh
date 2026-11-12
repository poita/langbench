#!/usr/bin/env bash
# Build the project and place the executable at bin/sat.
set -euo pipefail
cd "$(dirname "$0")"
cabal build -v1 exe:sat
mkdir -p bin
cp "$(cabal list-bin -v0 exe:sat)" bin/sat
