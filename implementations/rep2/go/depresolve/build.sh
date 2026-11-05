#!/bin/sh
# Builds the depresolve command into bin/depresolve. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/depresolve ./cmd/depresolve
