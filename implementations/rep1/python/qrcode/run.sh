#!/bin/sh
# Run the QR encoder CLI: queries on stdin, symbols on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m qrcode "$@"
