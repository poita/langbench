#!/bin/sh
# Build the depresolve command into ./bin/depresolve.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/depresolve ./cmd/depresolve
