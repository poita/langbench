#!/bin/sh
# Pure Python: nothing to compile. Byte-compile the sources as a sanity check.
set -e
here=$(cd "$(dirname "$0")" && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 -c "
import sys, pathlib
for p in pathlib.Path(sys.argv[1]).rglob('*.py'):
    compile(p.read_text(), str(p), 'exec')
" "$here/src"
