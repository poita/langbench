#!/bin/sh
# Build the rubiks command into bin/rubiks. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/rubiks ./cmd/rubiks
