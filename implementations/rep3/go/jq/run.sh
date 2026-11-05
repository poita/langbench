#!/bin/sh
# Run the jq tool: filter on the first stdin line, JSON document after it.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/jq" "$@"
