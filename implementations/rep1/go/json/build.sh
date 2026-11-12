#!/bin/sh
# Build the jsoncanon command-line tool into bin/jsoncanon.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/jsoncanon ./cmd/jsoncanon
