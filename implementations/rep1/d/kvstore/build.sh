#!/bin/sh
# Build the kvstore command-line tool into bin/kvstore.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli
