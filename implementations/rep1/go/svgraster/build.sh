#!/bin/sh
# Build the svgraster command-line tool into bin/svgraster.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/svgraster ./cmd/svgraster
