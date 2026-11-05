#!/bin/sh
# Build the bigint command-line tool into bin/bigint.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/bigint ./cmd/bigint
