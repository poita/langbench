#!/bin/sh
# Build the fulltext command-line tool into bin/fulltext.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --config=application --quiet
