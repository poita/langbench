#!/bin/sh
# Build the linalg command-line tool into bin/linalg.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/linalg ./cmd/linalg
