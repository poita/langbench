#!/bin/sh
# Builds the command-line tool into bin/commonmark.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 :cli
