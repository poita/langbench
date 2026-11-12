import sys

from .cli import main_with_big_stack

if __name__ == "__main__":
    sys.exit(main_with_big_stack(sys.argv[1:]))
