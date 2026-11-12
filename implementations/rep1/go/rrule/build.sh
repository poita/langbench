#!/bin/sh
# Build the rrule command-line tool into bin/rrule.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/rrule ./cmd/rrule
