#!/bin/sh
# Build the typeinfer executable and place a copy at dist/typeinfer.
set -e
cd "$(dirname "$0")"
cabal build exe:typeinfer
mkdir -p dist
cp "$(cabal list-bin exe:typeinfer)" dist/typeinfer
