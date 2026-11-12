#!/bin/sh
# Build the bigint command-line tool into bin/bigint.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=application "$@"
