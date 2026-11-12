#!/bin/sh
# Build the orderbook executable (standard cabal optimisation settings).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cabal build exe:orderbook >&2
