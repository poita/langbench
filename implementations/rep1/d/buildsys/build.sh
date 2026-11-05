#!/bin/sh
# Builds the project in release mode with LDC.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2
