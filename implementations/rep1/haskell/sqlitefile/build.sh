#!/bin/sh
# Build the sqlitefile executable (works from any current directory).
set -e
cd "$(dirname "$0")"
exec cabal build exe:sqlitefile -v0
