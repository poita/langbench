"""A deterministic CHIP-8 interpreter.

Typical use::

    from chip8 import Machine

    machine = Machine(bytes.fromhex("6001700112021200"))
    machine.run(10)
    print(machine.v[0])

See :func:`chip8.textio.simulate` for the text-in/text-out entry point used by
the command-line tool.
"""

from .font import FONT, FONT_ADDRESS
from .machine import (
    DISPLAY_HEIGHT,
    DISPLAY_WIDTH,
    MAX_ROM_SIZE,
    PROGRAM_START,
    KeyEvent,
    Machine,
)
from .textio import Program, parse_input, render, render_display, render_state, simulate

__all__ = [
    "DISPLAY_HEIGHT",
    "DISPLAY_WIDTH",
    "FONT",
    "FONT_ADDRESS",
    "MAX_ROM_SIZE",
    "PROGRAM_START",
    "KeyEvent",
    "Machine",
    "Program",
    "parse_input",
    "render",
    "render_display",
    "render_state",
    "simulate",
]

__version__ = "1.0.0"
