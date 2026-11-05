#!/bin/sh
# Builds the cardgame command-line tool into ./bin/cardgame.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/cardgame ./cmd/cardgame
