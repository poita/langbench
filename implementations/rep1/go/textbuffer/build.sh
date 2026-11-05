#!/bin/sh
# Builds bin/textbuffer. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/textbuffer ./cmd/textbuffer
