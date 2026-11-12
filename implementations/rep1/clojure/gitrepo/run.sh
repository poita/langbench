#!/bin/sh
# Usage: run.sh <input path> <output dir>
# Works from any current directory: relative arguments are made absolute
# before moving to the project directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac; }
in=$(abs "$1")
out=$(abs "$2")
cd "$dir"
exec clojure -M:run "$in" "$out"
