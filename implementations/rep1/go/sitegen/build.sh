#!/bin/sh
# Build the sitegen command-line tool into bin/sitegen.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/sitegen ./cmd/sitegen
