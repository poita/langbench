#!/bin/sh
# Build the regex command-line tool.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 -q
