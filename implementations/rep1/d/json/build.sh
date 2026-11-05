#!/bin/sh
# Build the canonjson command-line tool (bin/canonjson).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
