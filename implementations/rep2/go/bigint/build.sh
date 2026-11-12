#!/bin/sh
# Builds the bigint command-line tool into bin/bigint.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/bigint ./cmd/bigint
