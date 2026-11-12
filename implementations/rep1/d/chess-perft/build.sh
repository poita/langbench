#!/bin/sh
# Build the chess-perft command-line tool (release mode, LDC).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli --quiet
