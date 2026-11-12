#!/bin/sh
# Runs the jq tool: filter on the first stdin line, JSON document after it.
exec "$(dirname "$0")/bin/jq" "$@"
