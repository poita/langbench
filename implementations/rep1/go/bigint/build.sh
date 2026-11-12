#!/bin/sh
# Build the bigint command-line tool into bin/bigint.
set -e
cd "$(dirname "$0")"
go build -o bin/bigint ./cmd/bigint
