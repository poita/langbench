#!/bin/sh
# Build the gitrepo library and executable and install the executable at
# bin/gitrepo, where run.sh finds it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
cabal build exe:gitrepo
mkdir -p bin
cp "$(cabal list-bin exe:gitrepo)" bin/gitrepo
