#!/bin/sh
# Build the protowire command-line tool into bin/protowire.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
