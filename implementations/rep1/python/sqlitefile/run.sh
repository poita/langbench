#!/bin/sh
# Usage: run.sh <input directory> <output directory>
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m sqlitefile "$@"
