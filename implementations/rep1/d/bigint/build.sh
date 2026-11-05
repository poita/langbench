#!/bin/sh
# Build the bigint CLI (bin/bigint). Works from any current directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
