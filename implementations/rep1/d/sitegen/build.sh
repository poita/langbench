#!/bin/sh
# Build the sitegen command-line tool into bin/sitegen.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 "$@"
