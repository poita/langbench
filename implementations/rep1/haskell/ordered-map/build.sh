#!/bin/sh
# Build the library and CLI, and copy the executable to bin/ordered-map.
set -e
cd "$(dirname "$0")"
cabal build exe:ordered-map-cli
mkdir -p bin
cp "$(cabal list-bin exe:ordered-map-cli)" bin/ordered-map
