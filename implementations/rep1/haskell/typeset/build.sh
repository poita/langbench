#!/bin/sh
# Build the typeset library, command-line tool and test suite, and place the
# executable at bin/typeset.  Works from any current directory.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
cabal build exe:typeset
mkdir -p bin
cp "$(cabal list-bin exe:typeset)" bin/typeset
