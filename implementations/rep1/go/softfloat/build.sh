#!/bin/sh
# Build the softfloat command into ./bin/softfloat.
set -e
cd "$(dirname "$0")"
go build -o bin/softfloat ./cmd/softfloat
