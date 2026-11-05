#!/bin/sh
# Usage: run.sh <input path> <output dir>
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/bin/gitrepo" "$@"
