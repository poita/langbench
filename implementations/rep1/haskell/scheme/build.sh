#!/bin/sh
# Build the project and place the executable at bin/scheme.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
cabal build exe:scheme
mkdir -p "$DIR/bin"
cp "$(cabal list-bin exe:scheme)" "$DIR/bin/scheme"
