#!/bin/sh
# Build the project (works from any current directory) and copy the
# executable to bin/bigint so run.sh does not need cabal at run time.
set -e
cd "$(dirname "$0")"
cabal build exe:bigint
mkdir -p bin
cp "$(cabal list-bin exe:bigint)" bin/bigint
