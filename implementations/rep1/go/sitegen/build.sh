#!/bin/sh
# Build the sitegen command-line tool into bin/sitegen.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/sitegen ./cmd/sitegen
