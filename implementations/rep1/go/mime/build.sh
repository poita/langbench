#!/bin/sh
# Build the mime command into bin/mime. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/mime ./cmd/mime
