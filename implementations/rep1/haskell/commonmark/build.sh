#!/bin/sh
# Build the commonmark CLI and place the binary at bin/commonmark.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
cabal build exe:commonmark
mkdir -p bin
cp "$(cabal list-bin exe:commonmark)" bin/commonmark
