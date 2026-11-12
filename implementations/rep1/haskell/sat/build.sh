#!/bin/sh
# Build the project (library, executable and test suite) with cabal.
set -e
cd "$(dirname "$0")"
cabal build exe:sat
