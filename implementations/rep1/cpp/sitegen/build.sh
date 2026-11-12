#!/bin/sh
# Builds sitegen (library, CLI and unit tests) as a Release build.
# Works from any current directory; output goes to <project>/build.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release > "$dir/build.log" 2>&1 || { cat "$dir/build.log"; exit 1; }
cmake --build "$dir/build" --config Release -j 8 >> "$dir/build.log" 2>&1 || { cat "$dir/build.log"; exit 1; }
