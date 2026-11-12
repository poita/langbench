#!/bin/sh
# Usage: run.sh <input path> <output dir>
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m gitrepo "$@"
