#!/bin/sh
# Build the jq command-line tool into bin/jq.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
