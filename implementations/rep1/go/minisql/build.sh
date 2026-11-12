#!/bin/sh
# Build the minisql command-line tool into ./bin/minisql.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/minisql ./cmd/minisql
