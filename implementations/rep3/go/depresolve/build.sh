#!/bin/sh
# Builds the depresolve command-line tool into ./bin/depresolve.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/depresolve ./cmd/depresolve
