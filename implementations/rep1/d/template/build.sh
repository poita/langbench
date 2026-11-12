#!/bin/sh
# Build the jinjalite command-line tool into bin/jinjalite.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=application
