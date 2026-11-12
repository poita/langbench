#!/bin/sh
# Builds the protowire command-line tool into bin/protowire.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
