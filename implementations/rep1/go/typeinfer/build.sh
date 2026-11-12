#!/bin/sh
# Build the typeinfer command into bin/typeinfer.
set -e
cd "$(dirname "$0")"
go build -o bin/typeinfer ./cmd/typeinfer
