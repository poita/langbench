#!/bin/sh
# Builds the datalog command-line tool into bin/datalog.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/datalog ./cmd/datalog
