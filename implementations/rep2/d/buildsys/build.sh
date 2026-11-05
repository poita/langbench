#!/bin/sh
# Builds the buildsys command-line tool. Works from any current directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
