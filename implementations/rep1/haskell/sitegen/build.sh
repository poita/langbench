#!/bin/sh
# Build the sitegen executable and place it at bin/sitegen.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cabal build exe:sitegen
mkdir -p bin
cp "$(cabal list-bin exe:sitegen)" bin/sitegen
