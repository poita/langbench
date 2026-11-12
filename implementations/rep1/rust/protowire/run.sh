#!/bin/sh
# Run the protowire CLI: reads a schema and requests on stdin, writes results to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/protowire" "$@"
