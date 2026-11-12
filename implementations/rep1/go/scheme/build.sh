#!/bin/sh
# Build the scheme interpreter into bin/scheme.
set -e
cd "$(dirname "$0")"
go build -o bin/scheme ./cmd/scheme
