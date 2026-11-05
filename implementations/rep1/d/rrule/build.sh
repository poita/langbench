#!/bin/sh
# Build the rrule command-line tool (and library) in release mode.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli --quiet
