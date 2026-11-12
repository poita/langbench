#!/bin/sh
# Build the fulltext command-line tool into bin/fulltext.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/fulltext ./cmd/fulltext
