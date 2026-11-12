#!/bin/sh
# Builds the regexbt command-line tool into bin/regexbt.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/regexbt ./cmd/regexbt
