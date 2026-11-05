#!/bin/sh
# Build the jsoncanon command-line tool into bin/. Works from any directory.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/jsoncanon ./cmd/jsoncanon
