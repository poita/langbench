#!/bin/sh
# Build the tessera command-line tool into ./bin/tessera.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/tessera ./cmd/tessera
