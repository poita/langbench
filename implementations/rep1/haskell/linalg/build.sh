#!/bin/sh
# Build the linalg library and command line tool.
set -e
cd "$(dirname "$0")"
cabal build -v0 exe:linalg
