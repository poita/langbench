#!/bin/sh
# Run the kvstore tool: run.sh <input dir> <output dir>
ROOT=$(cd "$(dirname "$0")" && pwd)
exec "$ROOT/bin/kvstore" "$@"
