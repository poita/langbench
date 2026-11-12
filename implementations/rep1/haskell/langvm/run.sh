#!/usr/bin/env bash
# Run langvm: the module stream is read on stdin, the result goes to stdout.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/bin/langvm" "$@"
