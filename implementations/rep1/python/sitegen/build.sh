#!/bin/sh
# Build sitegen: byte-compile the package with the interpreter's standard
# (non-optimised) settings. The project has no compiled parts and no runtime
# dependencies, so this is all a build amounts to.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
exec python3 -m compileall -q src
