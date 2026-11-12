#!/bin/sh
# Build the diff command-line tool into bin/diff.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/diff ./cmd/diff
