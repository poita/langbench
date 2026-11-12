#!/bin/sh
# Builds the chess-perft command into bin/chess-perft.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/chess-perft ./cmd/chess-perft
