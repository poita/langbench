#!/bin/sh
# Build the gitrepo command-line tool into ./bin/gitrepo.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/gitrepo ./cmd/gitrepo
