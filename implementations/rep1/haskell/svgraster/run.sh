#!/bin/sh
# Usage: run.sh <input-dir> <output-dir>
set -e
cd "$(dirname "$0")"
exe=$(cabal list-bin -v0 exe:svgraster)
cd "$OLDPWD"
exec "$exe" "$@"
