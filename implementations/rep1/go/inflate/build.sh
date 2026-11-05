#!/bin/sh
# Build the inflate command into bin/inflate. Works from any directory.
set -e
cd "$(dirname "$0")"
go build -o bin/inflate ./cmd/inflate
