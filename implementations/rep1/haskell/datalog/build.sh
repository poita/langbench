#!/bin/sh
# Build the datalog executable and place it at bin/datalog.
set -e
cd "$(dirname "$0")"
cabal build -v1 exe:datalog
mkdir -p bin
cp "$(cabal list-bin -v0 exe:datalog)" bin/datalog
