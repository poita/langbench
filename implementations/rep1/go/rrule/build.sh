#!/bin/sh
# Build the rrule command-line tool into bin/rrule. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/rrule ./cmd/rrule
