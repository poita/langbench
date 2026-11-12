#!/bin/sh
# Build the sqlitefile command into bin/sqlitefile.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/sqlitefile ./cmd/sqlitefile
