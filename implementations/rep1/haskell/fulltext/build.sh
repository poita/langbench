#!/bin/sh
# Build the fulltext executable and copy it to bin/fulltext.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cabal build exe:fulltext
mkdir -p bin
cp "$(cabal list-bin exe:fulltext)" bin/fulltext
