#!/bin/sh
# Build the sat command into bin/sat.
set -e
cd "$(dirname "$0")"
go build -o bin/sat ./cmd/sat
