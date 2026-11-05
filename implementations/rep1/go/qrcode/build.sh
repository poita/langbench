#!/bin/sh
# Build the qrcode CLI into ./bin/qrcode. Works from any directory.
set -e
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/qrcode ./cmd/qrcode
