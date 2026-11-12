#!/bin/sh
# Build the template command into bin/template.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/template ./cmd/template
