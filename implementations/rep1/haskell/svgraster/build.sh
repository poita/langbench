#!/bin/sh
# Build the svgraster library, executable and test suite.
set -e
cd "$(dirname "$0")"
cabal build all --enable-tests -v0
