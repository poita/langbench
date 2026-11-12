#!/bin/sh
# Builds the langvm command into bin/langvm. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/langvm ./cmd/langvm
