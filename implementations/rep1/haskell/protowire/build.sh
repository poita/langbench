#!/usr/bin/env bash
# Build the protowire CLI and copy the binary to bin/protowire.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
cabal build -v1 exe:protowire
mkdir -p bin
cp "$(cabal list-bin -v0 exe:protowire)" bin/protowire
