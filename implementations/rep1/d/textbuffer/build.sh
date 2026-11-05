#!/bin/sh
# Build the textbuffer command-line tool into bin/textbuffer.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
dub build -b release --compiler=ldc2 -c cli --quiet
