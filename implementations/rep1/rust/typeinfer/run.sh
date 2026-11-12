#!/bin/sh
# Run the CLI: program on stdin, declaration types on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/typeinfer" "$@"
