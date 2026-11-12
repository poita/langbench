#!/bin/sh
# Build the cardgame CLI with cabal and place the binary at bin/cardgame.
# Works from any current directory.
set -e
cd "$(dirname "$0")"
cabal build exe:cardgame
mkdir -p bin
cp "$(cabal list-bin -v0 exe:cardgame)" bin/cardgame
