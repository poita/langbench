#!/bin/sh
# Run the typesetter: run.sh <input directory> <output directory>
# The current directory is left alone; `data/` is resolved against it.
DIR=$(cd "$(dirname "$0")" && pwd)
exec clojure -Sdeps "{:deps {typeset/typeset {:local/root \"$DIR\"}}}" -M -m typeset.cli "$@"
