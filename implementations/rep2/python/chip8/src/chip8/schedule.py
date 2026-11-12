"""Key schedules: timed changes of the held-key state."""

from typing import NamedTuple

from .machine import Machine


class KeyEvent(NamedTuple):
    """From just before cycle ``cycle`` executes, ``mask`` is the held-key state."""

    cycle: int
    mask: int


def parse_key_schedule(text: str) -> list[KeyEvent]:
    """Parse ``"<cycle>:<hexmask> ..."`` (space separated); empty text gives no events."""
    events = []
    for token in text.split():
        cycle, _, mask = token.partition(":")
        events.append(KeyEvent(int(cycle), int(mask, 16)))
    return events


def run_with_schedule(
    machine: Machine, cycles: int, schedule: list[KeyEvent] | tuple[KeyEvent, ...] = ()
) -> None:
    """Run ``machine`` until it has completed ``cycles`` cycles in total.

    Events (which must be sorted by cycle) are consumed in order, each one
    applied just before its cycle executes. Events at or after ``cycles``
    never take effect. Per-cycle work is O(1): the machine runs in bulk
    between consecutive events.
    """
    for event in schedule:
        if event.cycle >= cycles:
            break
        if event.cycle > machine.cycles:
            machine.run(event.cycle - machine.cycles)
        machine.set_keys(event.mask)
    machine.run(cycles - machine.cycles)
