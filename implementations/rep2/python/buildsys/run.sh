#!/bin/sh
# Run the Kiln CLI: run.sh <input directory> <output directory>
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m kiln "$@"
