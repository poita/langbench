#!/bin/sh
# Run the mdiff CLI: reads stdin, writes stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/mdiff"
