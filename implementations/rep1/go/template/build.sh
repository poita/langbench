#!/bin/sh
# Build the template command-line tool into bin/template.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/template ./cmd/template
