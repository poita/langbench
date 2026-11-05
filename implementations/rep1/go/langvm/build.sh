#!/bin/sh
# Build the langvm command into ./bin/langvm. Works from any directory.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/langvm ./cmd/langvm
