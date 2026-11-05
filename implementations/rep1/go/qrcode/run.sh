#!/bin/sh
# Run the qrcode CLI: queries on stdin, symbols on stdout.
exec "$(dirname "$0")/bin/qrcode" "$@"
