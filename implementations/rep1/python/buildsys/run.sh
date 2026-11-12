#!/bin/sh
# Run Kiln: run.sh <input directory> <output directory>
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m kiln "$@"
