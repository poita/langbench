#!/bin/sh
# Build the datalog command-line tool into bin/datalog.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 -q
