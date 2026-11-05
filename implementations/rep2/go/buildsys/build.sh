#!/bin/sh
# Builds the kiln command-line tool into ./bin/kiln.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/kiln ./cmd/kiln
