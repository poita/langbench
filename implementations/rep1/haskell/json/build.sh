#!/bin/sh
# Build the project and place the CLI binary at bin/json-canon.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
cabal build exe:json-canon
mkdir -p "$DIR/bin"
cp "$(cabal list-bin exe:json-canon)" "$DIR/bin/json-canon"
