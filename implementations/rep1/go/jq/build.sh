#!/bin/sh
# Build the jq command into bin/jq. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/jq ./cmd/jq
