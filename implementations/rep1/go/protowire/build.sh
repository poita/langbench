#!/bin/sh
# Build the protowire CLI into ./bin/protowire. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o "$dir/bin/protowire" ./cmd/protowire
