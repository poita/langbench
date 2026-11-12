#!/bin/sh
# Run depresolve: reads a registry + root manifest on stdin, writes the resolution to stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m depresolve "$@"
