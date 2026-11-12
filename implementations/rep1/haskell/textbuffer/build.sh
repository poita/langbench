#!/bin/sh
# Build the textbuffer command-line tool with cabal.
set -e
cd "$(dirname "$0")"
cabal build -v1 exe:textbuffer
mkdir -p bin
cp "$(cabal list-bin -v0 exe:textbuffer)" bin/textbuffer
