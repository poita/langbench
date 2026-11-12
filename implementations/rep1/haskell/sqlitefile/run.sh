#!/bin/sh
# Usage: run.sh <input dir> <output dir>
# Locates the built executable relative to this script; keeps the caller's cwd
# so relative input/output paths keep working.
dir=$(cd "$(dirname "$0")" && pwd)
exe=$(cd "$dir" && cabal list-bin exe:sqlitefile -v0) || exit 1
exec "$exe" "$@"
