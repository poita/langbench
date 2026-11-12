#!/bin/sh
# Builds the jsonschema CLI in release mode (output: ./jsonschema/jsonschema).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
