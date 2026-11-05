#!/bin/sh
# Usage: run.sh <input-dir> <output-dir>
exec "$(cd "$(dirname "$0")" && pwd)/bin/svgraster" "$@"
