#!/bin/sh
# Builds the spreadsheet CLI into ./bin/spreadsheet.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/spreadsheet ./cmd/spreadsheet
