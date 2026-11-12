#!/bin/sh
# Usage: run.sh <input directory> <output directory>
here=$(cd "$(dirname "$0")" && pwd) || exit 1
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m linalg "$@"
