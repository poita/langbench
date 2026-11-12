#!/bin/sh
# Builds the orderbook CLI into bin/orderbook. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/orderbook ./cmd/orderbook
