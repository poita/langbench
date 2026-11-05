#!/bin/sh
# Runs the webhooks command-line tool: command stream on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/webhooks" "$@"
