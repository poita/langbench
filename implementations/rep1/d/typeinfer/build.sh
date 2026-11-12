#!/bin/sh
# Build the typeinfer command-line tool into bin/typeinfer.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli
