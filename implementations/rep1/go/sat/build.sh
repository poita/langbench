#!/bin/sh
# Build the sat command-line tool into bin/sat.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/sat ./cmd/sat
