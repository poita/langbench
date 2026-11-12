#!/bin/sh
# Build the project and install the executable at bin/bigint.
set -e
cd "$(dirname "$0")"
cabal build exe:bigint
mkdir -p bin
cp "$(cabal list-bin exe:bigint)" bin/bigint
