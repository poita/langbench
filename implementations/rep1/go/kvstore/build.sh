#!/bin/sh
# Build the kvstore command-line tool into bin/kvstore.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/kvstore ./cmd/kvstore
