#!/bin/sh
# Build the spreadsheet CLI into ./bin/sheet.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/sheet ./cmd/sheet
