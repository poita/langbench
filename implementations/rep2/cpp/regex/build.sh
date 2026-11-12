#!/usr/bin/env bash
# Configure and build the project (Release) into <project>/build.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" --config Release -j 8
