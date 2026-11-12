#!/bin/sh
# Builds the textbuffer command-line tool into bin/textbuffer.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/textbuffer ./cmd/textbuffer
