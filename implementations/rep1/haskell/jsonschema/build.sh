#!/bin/sh
# Build the jsonschema library and command-line tool, and place the binary in
# bin/ so that run.sh can start it without consulting cabal.
set -e
cd "$(dirname "$0")"
cabal build exe:jsonschema 1>&2
mkdir -p bin
cp "$(cabal list-bin exe:jsonschema)" bin/jsonschema
