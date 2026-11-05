#!/bin/sh
# Build the diff command into bin/diff. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/diff ./cmd/diff
