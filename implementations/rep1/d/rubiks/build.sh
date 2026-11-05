#!/bin/sh
# Build the rubiks command-line tool into bin/rubiks.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
