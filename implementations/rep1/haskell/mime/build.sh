#!/bin/sh
# Build the mime-dump executable and copy it to bin/ so run.sh can find it.
set -e
cd "$(dirname "$0")"
cabal build exe:mime-dump
mkdir -p bin
cp "$(cabal list-bin exe:mime-dump)" bin/mime-dump
