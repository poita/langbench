#!/bin/sh
# Build the depresolve command-line tool into bin/depresolve.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/depresolve ./cmd/depresolve
