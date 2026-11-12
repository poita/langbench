#!/bin/sh
# Build the linalg command-line tool into ./bin/linalg.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/linalg ./cmd/linalg
