#!/bin/sh
# Build the fulltext command-line tool into bin/fulltext.
set -e
cd "$(dirname "$0")"
go build -o bin/fulltext ./cmd/fulltext
