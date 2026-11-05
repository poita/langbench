#!/bin/sh
# Build the datalog command-line tool into ./bin/datalog.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/datalog ./cmd/datalog
