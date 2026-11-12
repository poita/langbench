#!/bin/sh
# Build the buildsys executable with cabal and install a copy at bin/buildsys
# so that run.sh does not need cabal at run time.
set -e
cd "$(dirname "$0")"
cabal build exe:buildsys >&2
mkdir -p bin
cp "$(cabal list-bin exe:buildsys)" bin/buildsys
