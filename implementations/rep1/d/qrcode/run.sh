#!/bin/sh
# Run the qrcode tool: queries on stdin, symbols on stdout.
exec "$(dirname "$0")/qrcode" "$@"
