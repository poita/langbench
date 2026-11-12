#!/bin/sh
# Pure-Python project: "building" just byte-compiles the sources (optional).
here=$(cd "$(dirname "$0")" && pwd)
python3 -m compileall -q "$here/src" >/dev/null 2>&1 || true
exit 0
