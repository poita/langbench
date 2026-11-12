#!/bin/sh
# Builds the project (Release) into ./build, from any current directory.
set -e
root="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$root" -B "$root/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$root/build" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
