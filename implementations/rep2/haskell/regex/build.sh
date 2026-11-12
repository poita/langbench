#!/bin/sh
# Build the project (library, CLI and test suite) with cabal.
set -e
cd "$(dirname "$0")"
cabal build exe:regex-backtrack
