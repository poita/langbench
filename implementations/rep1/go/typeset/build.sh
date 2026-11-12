#!/bin/sh
# Build the typeset command into ./bin/typeset.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/typeset ./cmd/typeset
