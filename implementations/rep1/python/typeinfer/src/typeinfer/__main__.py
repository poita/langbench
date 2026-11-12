import os
import sys

from .cli import main

status = main()
sys.stdout.flush()
# Skip interpreter teardown (freeing large type graphs is pure overhead).
os._exit(status)
