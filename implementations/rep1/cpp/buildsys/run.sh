#!/bin/bash
# Usage: run.sh <input directory> <output directory>
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$here/build/kiln" "$@"
