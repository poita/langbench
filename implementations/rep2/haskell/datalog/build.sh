#!/bin/sh
# Build the project and place the executable at bin/datalog.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
cabal build exe:datalog
mkdir -p bin
cp "$(cabal list-bin exe:datalog)" bin/datalog
