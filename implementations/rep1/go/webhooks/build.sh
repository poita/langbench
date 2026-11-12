#!/bin/sh
# Build the webhooks CLI into ./bin/webhooks.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/webhooks ./cmd/webhooks
