#!/bin/sh
# Build the protowire CLI into bin/protowire. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/protowire ./cmd/protowire
