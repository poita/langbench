#!/bin/sh
# Build the project and stage the executable at bin/buildsys.
set -e
cd "$(dirname "$0")"
cabal build -v1 exe:buildsys
mkdir -p bin
cp "$(cabal list-bin -v0 exe:buildsys)" bin/buildsys
