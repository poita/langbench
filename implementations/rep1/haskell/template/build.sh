#!/bin/sh
# Build the CLI and place it at bin/template.
set -e
cd "$(dirname "$0")"
cabal build exe:template
mkdir -p bin
cp "$(cabal list-bin exe:template)" bin/template
