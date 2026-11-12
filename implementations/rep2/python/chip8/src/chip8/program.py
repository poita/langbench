"""Reading the textual program format and rendering the final state."""

from typing import NamedTuple

from .machine import Machine
from .schedule import KeyEvent, parse_key_schedule, run_with_schedule


class Program(NamedTuple):
    """A parsed input: ROM image, cycle budget and key schedule."""

    rom: bytes
    cycles: int
    schedule: list[KeyEvent]


def parse_program(text: str) -> Program:
    """Parse the three-line input (ROM hex, cycle count, optional key schedule)."""
    lines = text.split("\n")
    if len(lines) < 2:
        raise ValueError("input needs at least a ROM line and a cycle-count line")
    rom = bytes.fromhex(lines[0].strip())
    cycles = int(lines[1].strip())
    schedule = parse_key_schedule(lines[2]) if len(lines) > 2 else []
    return Program(rom, cycles, schedule)


def format_state(machine: Machine) -> str:
    """Render the display and CPU state as the 34-line report."""
    out = machine.display.rows()
    out.append(
        f"PC={machine.pc:04x} I={machine.i:04x} SP={machine.sp} "
        f"DT={machine.dt:02x} ST={machine.st:02x}"
    )
    out.append("V=" + " ".join(f"{r:02x}" for r in machine.v))
    return "\n".join(out) + "\n"


def run_program(text: str) -> str:
    """Run a program given in the textual input format and return the report."""
    program = parse_program(text)
    machine = Machine(program.rom)
    run_with_schedule(machine, program.cycles, program.schedule)
    return format_state(machine)
