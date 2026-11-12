#!/bin/sh
# Run fulltext: run.sh <input dir> <output dir>
ROOT=$(cd "$(dirname "$0")" && pwd)
exec java -cp "$(cat "$ROOT/target/classpath.txt")" fulltext.main "$@"
