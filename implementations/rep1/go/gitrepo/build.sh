#!/bin/sh
# Build the gitrepo command-line tool into bin/gitrepo.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/gitrepo ./cmd/gitrepo
