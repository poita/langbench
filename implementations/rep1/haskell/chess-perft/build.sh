#!/bin/sh
# Build the chess-perft library and executable, and copy the executable to
# bin/chess-perft (where run.sh looks for it).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
cabal build exe:chess-perft
mkdir -p bin
cp "$(cabal list-bin exe:chess-perft)" bin/chess-perft
