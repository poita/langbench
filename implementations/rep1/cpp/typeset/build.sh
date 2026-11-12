#!/usr/bin/env bash
# Configure and build the project (Release) into ./build.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
