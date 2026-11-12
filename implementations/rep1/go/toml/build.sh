#!/bin/sh
# Builds the command-line tool into bin/toml.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/toml ./cmd/toml
