#!/bin/sh
# Builds the qrcode command-line tool into ./bin/qrcode.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/qrcode ./cmd/qrcode
