#!/bin/sh
# Build the svgraster command into bin/svgraster.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
go build -o bin/svgraster ./cmd/svgraster
