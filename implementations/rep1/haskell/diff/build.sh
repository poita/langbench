#!/bin/sh
# Build the project and place the CLI binary at bin/diff-cli.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
cabal build exe:diff-cli -v1 >&2
mkdir -p bin
cp "$(cabal list-bin exe:diff-cli)" bin/diff-cli
