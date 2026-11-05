#!/bin/sh
# Build the regex command into bin/regex. Works from any directory.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/regex ./cmd/regex
