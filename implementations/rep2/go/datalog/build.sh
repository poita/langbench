#!/bin/sh
# Build the datalog command into bin/datalog. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/datalog ./cmd/datalog
