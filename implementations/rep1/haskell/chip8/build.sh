#!/bin/sh
# Build the chip8 executable and place a copy in bin/.
set -e
cd "$(dirname "$0")"
cabal build exe:chip8
mkdir -p bin
cp "$(cabal list-bin -v0 exe:chip8)" bin/chip8
