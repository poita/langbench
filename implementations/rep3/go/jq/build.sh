#!/bin/sh
# Build the jq command-line tool into bin/jq.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/jq ./cmd/jq
