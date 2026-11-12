#!/bin/sh
# Configure and build the library, the CLI and the tests (Release).
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$dir/build" --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
