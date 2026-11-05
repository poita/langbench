#!/bin/sh
# Run the jq command: filter on the first stdin line, JSON document after it.
exec "$(dirname "$0")/bin/jq" "$@"
