#!/bin/sh
# Build the regex command into bin/regex. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/regex ./cmd/regex
