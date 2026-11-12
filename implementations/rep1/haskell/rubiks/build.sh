#!/bin/sh
# Build the rubiks library and CLI, and copy the executable to bin/rubiks.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
cabal build exe:rubiks
mkdir -p bin
cp "$(cabal list-bin -v0 exe:rubiks)" bin/rubiks
