#!/bin/sh
# Build the jq command into bin/jq.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/jq ./cmd/jq
