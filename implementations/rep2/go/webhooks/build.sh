#!/bin/sh
# Builds the webhooks command-line tool into bin/webhooks.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/webhooks ./cmd/webhooks
