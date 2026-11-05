#!/bin/sh
# Build the command-line tool into bin/toml. Works from any directory.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/toml ./cmd/toml
