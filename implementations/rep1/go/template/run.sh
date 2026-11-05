#!/bin/sh
# Run the template tool: reads the bundle on stdin, writes the rendering to stdout.
exec "$(dirname "$0")/bin/template" "$@"
