#!/bin/sh
# Build the sat command-line tool into ./bin/sat (relative to this script).
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/sat ./cmd/sat
