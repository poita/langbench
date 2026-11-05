#!/bin/sh
# Run the jtemplate command-line tool: stdin -> stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/jtemplate" "$@"
