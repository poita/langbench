#!/bin/sh
# Configures and builds langvm (Release) into ./build, from any directory.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release -DLANGVM_BUILD_TESTS="${LANGVM_BUILD_TESTS:-ON}" >/dev/null
cmake --build "$here/build" --config Release -j 8
