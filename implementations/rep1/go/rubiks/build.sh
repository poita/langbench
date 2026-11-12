#!/bin/sh
# Build the rubiks command-line tool into ./bin/rubiks.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/rubiks ./cmd/rubiks
