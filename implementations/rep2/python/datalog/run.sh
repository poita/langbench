#!/bin/sh
# Run the Datalog CLI: program on stdin, answers on stdout.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m datalog "$@"
