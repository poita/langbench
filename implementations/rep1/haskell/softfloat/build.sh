#!/bin/sh
# Build the softfloat executable (works from any directory).
set -e
cd "$(dirname "$0")"
cabal build exe:softfloat -v0
