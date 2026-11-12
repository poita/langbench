#!/bin/sh
# Usage: run.sh <input directory> <output directory>
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/buildsys" "$@"
