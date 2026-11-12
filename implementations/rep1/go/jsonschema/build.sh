#!/bin/sh
# Builds the jsonschema command-line tool into bin/jsonschema.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/jsonschema ./cmd/jsonschema
