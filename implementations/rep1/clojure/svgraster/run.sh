#!/bin/sh
# Usage: run.sh <input-dir> <output-dir>
# Works from any current directory: relative arguments are made absolute first.
here=$(cd "$(dirname "$0")" && pwd)
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
if [ "$#" -ge 2 ]; then
  in=$(abs "$1"); out=$(abs "$2")
  cd "$here" && exec clojure -M -m svgraster.main "$in" "$out"
fi
cd "$here" && exec clojure -M -m svgraster.main "$@"
