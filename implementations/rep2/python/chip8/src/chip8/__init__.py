"""chip8: a deterministic CHIP-8 interpreter.

Public API::

    from chip8 import Machine, run_program

    machine = Machine(bytes.fromhex("6001"))
    machine.run(1)                      # execute one cycle
    report = run_program("6001\\n1\\n")  # full text-in / text-out pipeline
"""

from .display import Display
from .machine import Machine
from .program import Program, format_state, parse_program, run_program
from .rng import Lcg
from .schedule import KeyEvent, parse_key_schedule, run_with_schedule

__all__ = [
    "Display",
    "KeyEvent",
    "Lcg",
    "Machine",
    "Program",
    "format_state",
    "parse_key_schedule",
    "parse_program",
    "run_program",
    "run_with_schedule",
]
__version__ = "1.0.0"
