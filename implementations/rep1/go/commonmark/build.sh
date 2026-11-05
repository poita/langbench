#!/bin/sh
# Build the commonmark command-line tool into bin/commonmark.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/commonmark ./cmd/commonmark
