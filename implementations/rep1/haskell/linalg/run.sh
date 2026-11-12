#!/bin/sh
# Usage: run.sh <input directory> <output directory>
set -e
cd "$(dirname "$0")"
exe=$(cabal list-bin -v0 exe:linalg)
cd "$OLDPWD"
exec "$exe" "$@"
