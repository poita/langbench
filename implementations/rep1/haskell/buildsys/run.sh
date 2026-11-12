#!/bin/sh
# Usage: run.sh <input directory> <output directory>
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$dir/bin/buildsys" ]; then
  exec "$dir/bin/buildsys" "$@"
fi
cd "$dir" && exec "$(cabal list-bin -v0 exe:buildsys)" "$@"
