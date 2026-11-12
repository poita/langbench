#!/bin/sh
# Build the kvstore command-line tool and place the binary at bin/kvstore.
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
cabal build exe:kvstore
mkdir -p "$ROOT/bin"
cp "$(cabal list-bin exe:kvstore)" "$ROOT/bin/kvstore"
