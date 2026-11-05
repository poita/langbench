#!/bin/sh
# Build the typeset command-line tool into ./bin/typeset.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/typeset ./cmd/typeset
