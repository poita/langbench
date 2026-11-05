#!/bin/sh
# Build the ordered-map command-line tool into ./bin/ordered-map.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/ordered-map ./cmd/ordered-map
