#!/bin/sh
# Build the jq CLI (release mode, LDC).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=application
