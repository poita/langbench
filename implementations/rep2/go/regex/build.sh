#!/bin/sh
# Builds the command-line tool into bin/regex. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/regex ./cmd/regex
