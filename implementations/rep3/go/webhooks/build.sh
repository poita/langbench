#!/bin/sh
# Build the webhooks command-line tool into bin/webhooks.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/webhooks ./cmd/webhooks
