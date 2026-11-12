#!/bin/sh
# Usage: run.sh <input directory> <output directory>
# Works from any current directory: the arguments are made absolute first.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
in="$(cd "$1" && pwd)"
out="$(cd "$2" && pwd)"
cd "$here"
exec clojure -M -m linalg.cli "$in" "$out"
