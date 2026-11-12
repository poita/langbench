#!/bin/sh
# Run linalg: run.sh <input directory> <output directory>
exec "$(dirname "$0")/target/release/linalg" "$@"
