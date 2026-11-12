#!/bin/sh
# Build the project and place the CLI binary at bin/regex-backtrack.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cabal build exe:regex-backtrack
mkdir -p bin
cp "$(cabal list-bin exe:regex-backtrack)" bin/regex-backtrack
