#!/bin/sh
# Build the mime command-line tool into ./bin/mime.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/mime ./cmd/mime
