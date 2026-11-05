#!/bin/sh
# Build the scheme CLI into bin/scheme. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/scheme ./cmd/scheme
