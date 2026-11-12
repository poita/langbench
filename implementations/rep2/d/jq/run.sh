#!/bin/sh
# Run the jq CLI: filter on the first stdin line, JSON document after it.
exec "$(dirname "$0")/jq" "$@"
