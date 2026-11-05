#!/bin/sh
# Builds the toml command-line tool into bin/toml.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/toml ./cmd/toml
