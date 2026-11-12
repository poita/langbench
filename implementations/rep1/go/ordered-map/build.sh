#!/bin/sh
# Builds the ordered-map binary into ./bin/. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/ordered-map ./cmd/ordered-map
