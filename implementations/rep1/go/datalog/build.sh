#!/bin/sh
# Builds the datalog CLI into ./bin/datalog. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/datalog ./cmd/datalog
