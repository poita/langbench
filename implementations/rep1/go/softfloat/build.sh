#!/bin/sh
# Builds the softfloat CLI into bin/softfloat. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/softfloat ./cmd/softfloat
