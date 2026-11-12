#!/bin/sh
# Run sitegen: run.sh <input directory> <output directory>. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/sitegen" "$@"
