#!/bin/sh
# Build the langvm command-line tool (output: bin/langvm).
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2
