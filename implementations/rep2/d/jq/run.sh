#!/bin/sh
# Run the jq tool: filter on the first stdin line, JSON document after it.
exec "$(cd "$(dirname "$0")" && pwd)/bin/jq" "$@"
