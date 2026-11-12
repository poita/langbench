#!/bin/sh
# Usage: run.sh <input directory> <output directory>
# Font and hyphenation data are read from ./data relative to the current
# working directory (see SPEC.md).
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m typeset "$@"
