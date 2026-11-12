#!/bin/sh
# Build the project and copy the CLI binary to bin/jq-hs.
set -e
cd "$(dirname "$0")"
cabal build exe:jq-hs
mkdir -p bin
cp "$(cabal list-bin -v0 exe:jq-hs)" bin/jq-hs
