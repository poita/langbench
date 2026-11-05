#!/bin/sh
# Builds the toml command-line tool into bin/toml. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/toml ./cmd/toml
