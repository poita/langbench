#!/bin/sh
# Usage: run.sh <input directory> <output directory>
root="$(cd "$(dirname "$0")" && pwd)"
exec "$root/build/kiln" "$@"
