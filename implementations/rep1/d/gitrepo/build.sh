#!/bin/sh
# Build the gitrepo command-line tool (works from any directory).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
dub build -b release --compiler=ldc2 --config=application --quiet
