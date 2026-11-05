#!/bin/sh
# Build the orderbook CLI into bin/orderbook. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -trimpath -o bin/orderbook ./cmd/orderbook
