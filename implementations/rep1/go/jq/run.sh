#!/bin/sh
# Run the jq command: filter on the first stdin line, document on the rest.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/jq" "$@"
