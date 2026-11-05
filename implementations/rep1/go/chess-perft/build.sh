#!/bin/sh
# Build the chess-perft command-line tool into ./bin/chess-perft.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/chess-perft ./cmd/chess-perft
