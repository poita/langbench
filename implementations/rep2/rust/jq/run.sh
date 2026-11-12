#!/bin/sh
# Run the jq binary: filter on the first stdin line, JSON document after it.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/jq" "$@"
