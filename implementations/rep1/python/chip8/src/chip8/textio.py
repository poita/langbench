"""Parsing of the textual input format and rendering of the textual output."""

from __future__ import annotations

from typing import NamedTuple

from .machine import DISPLAY_HEIGHT, DISPLAY_WIDTH, KeyEvent, Machine


class Program(NamedTuple):
    """A parsed input: ROM image, cycle budget and key schedule."""

    rom: bytes
    cycles: int
    key_schedule: tuple[KeyEvent, ...]


def parse_input(text: str) -> Program:
    """Parse the three-line input format.

    Line 1 is the ROM as lowercase hex, line 2 the decimal cycle count and the
    optional line 3 a space-separated list of ``<cycle>:<mask>`` key events.

    Raises:
        ValueError: if the text is malformed.
    """
    lines = text.split("\n")
    if len(lines) < 2:
        raise ValueError("input must contain a ROM line and a cycle-count line")
    rom = bytes.fromhex(lines[0].strip())
    cycles = int(lines[1].strip())
    if cycles < 0:
        raise ValueError("cycle count must not be negative")
    events: list[KeyEvent] = []
    if len(lines) > 2:
        for field in lines[2].split():
            cycle, _, mask = field.partition(":")
            events.append(KeyEvent(int(cycle), int(mask, 16)))
    return Program(rom, cycles, tuple(events))


def render_display(machine: Machine) -> str:
    """Return the display as 32 newline-terminated lines of ``#`` and ``.``."""
    chars = machine.display.translate(_PIXEL_TABLE).decode("ascii")
    return "".join(
        chars[row * DISPLAY_WIDTH : (row + 1) * DISPLAY_WIDTH] + "\n" for row in range(DISPLAY_HEIGHT)
    )


_PIXEL_TABLE = bytes([ord(".")] + [ord("#")] * 255)


def render_state(machine: Machine) -> str:
    """Return the two register-summary lines, each newline-terminated."""
    registers = " ".join(f"{value:02x}" for value in machine.v)
    return (
        f"PC={machine.pc:04x} I={machine.i:04x} SP={len(machine.stack)} "
        f"DT={machine.dt:02x} ST={machine.st:02x}\n"
        f"V={registers}\n"
    )


def render(machine: Machine) -> str:
    """Return the full 34-line output for ``machine``."""
    return render_display(machine) + render_state(machine)


def simulate(text: str) -> str:
    """Run the program described by the input ``text`` and return the output."""
    program = parse_input(text)
    machine = Machine(program.rom)
    machine.run(program.cycles, program.key_schedule)
    return render(machine)
