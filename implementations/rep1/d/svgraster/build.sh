#!/bin/sh
# Build the svgraster command-line tool (bin/svgraster) with dub + LDC.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli
