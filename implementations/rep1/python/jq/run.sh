#!/bin/sh
# Run jqlite: filter on the first stdin line, JSON document on the rest.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m jqlite "$@"
