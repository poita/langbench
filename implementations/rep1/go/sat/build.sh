#!/bin/sh
# Build the sat command-line tool into bin/sat. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/sat ./cmd/sat
