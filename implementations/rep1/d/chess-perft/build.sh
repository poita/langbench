#!/bin/sh
# Build the chess-perft command-line tool (and library) in release mode.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
