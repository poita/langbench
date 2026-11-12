#!/bin/sh
# Run the validator: JSON document on stdin, one valid/invalid line per test.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m jsonschema2020 "$@"
