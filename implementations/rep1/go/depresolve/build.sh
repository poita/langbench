#!/bin/sh
# Build the depresolve CLI into ./bin/depresolve.
set -e
cd "$(dirname "$0")"
go build -o bin/depresolve ./cmd/depresolve
