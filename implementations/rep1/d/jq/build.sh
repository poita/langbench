#!/bin/sh
# Build the jq tool (release) with dub + LDC.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli
