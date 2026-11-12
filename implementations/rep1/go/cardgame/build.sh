#!/bin/sh
# Build the cardgame binary into ./bin/cardgame. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/cardgame ./cmd/cardgame
