#!/bin/sh
# Build the datalog command-line tool (bin/datalog). Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=cli 1>&2
