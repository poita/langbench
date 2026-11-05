#!/bin/sh
# Builds the typeset command-line tool into bin/typeset.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
dub build -b release --compiler=ldc2 :cli
