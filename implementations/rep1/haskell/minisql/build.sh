#!/bin/sh
# Build the minisql executable and copy it to bin/minisql.
set -e
cd "$(dirname "$0")"
cabal build exe:minisql
mkdir -p bin
cp "$(cabal list-bin exe:minisql)" bin/minisql
