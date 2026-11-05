#!/bin/sh
# Build the typeinfer command-line tool into bin/typeinfer.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/typeinfer ./cmd/typeinfer
