#!/bin/sh
# Runs the jq CLI: filter on the first stdin line, JSON document after it.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/jq"
