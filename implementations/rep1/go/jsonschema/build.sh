#!/bin/sh
# Build the jsonschema command-line tool into ./bin/jsonschema.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/jsonschema ./cmd/jsonschema
