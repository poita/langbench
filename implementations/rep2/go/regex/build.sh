#!/bin/sh
# Build the regexvm command into bin/regexvm. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/regexvm ./cmd/regexvm
