#!/bin/sh
# Build the jq command-line tool into bin/jq. Works from any directory.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/jq ./cmd/jq
