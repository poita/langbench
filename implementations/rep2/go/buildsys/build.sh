#!/bin/sh
# Build the kiln command into bin/kiln. Works from any directory.
set -e
cd "$(dirname "$0")"
go build -o bin/kiln ./cmd/kiln
