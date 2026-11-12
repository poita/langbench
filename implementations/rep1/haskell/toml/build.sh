#!/bin/sh
# Build the project and place the executable at bin/toml.
set -e
cd "$(dirname "$0")"
cabal build -v0 exe:toml
mkdir -p bin
cp "$(cabal list-bin -v0 exe:toml)" bin/toml
