#!/bin/bash
# Builds Kiln (Release) into ./build next to this script. Works from any directory.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" --parallel
