#!/bin/sh
# Configure and build the library, the CLI and the unit tests (Release).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >&2
cmake --build "$here/build" --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)" >&2
