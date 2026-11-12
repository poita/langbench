#!/bin/sh
# Build the depresolve executable (works from any current directory).
set -e
cd "$(dirname "$0")"
cabal build exe:depresolve -v0
