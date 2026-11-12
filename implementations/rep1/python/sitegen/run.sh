#!/bin/sh
# Run sitegen:  run.sh <input directory> <output directory>
DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m sitegen "$@"
