"""The line-oriented command language: parsing input and running commands."""

from __future__ import annotations

import re
from collections.abc import Callable, Iterable
from typing import TextIO

from .buffer import Direction, TextBuffer


class CommandError(ValueError):
    """Raised for a malformed or unknown command."""


_ESCAPE = re.compile(r"\\(.)", re.DOTALL)


def decode_text(raw: str) -> str:
    """Decode an ``insert`` argument: ``\\n`` is a newline, ``\\\\`` a backslash."""
    if "\\" not in raw:
        return raw
    return _ESCAPE.sub(lambda m: "\n" if m.group(1) == "n" else m.group(1), raw)


def parse_input(data: str) -> tuple[list[str], list[str]]:
    """Split program input into ``(initial_document_lines, command_lines)``."""
    rows = data.split("\n")
    if rows and rows[-1] == "":
        rows.pop()
    if not rows:
        return [], []
    try:
        count = int(rows[0])
    except ValueError:
        raise CommandError(f"invalid line count: {rows[0]!r}") from None
    return rows[1 : 1 + count], rows[1 + count :]


def _int(word: str) -> int:
    try:
        return int(word)
    except ValueError:
        raise CommandError(f"invalid integer: {word!r}") from None


class Interpreter:
    """Runs textual commands against a :class:`TextBuffer`."""

    def __init__(self, buffer: TextBuffer, out: TextIO) -> None:
        self.buffer = buffer
        self.out = out
        self._simple: dict[str, Callable[[], None]] = {
            "delete": buffer.delete,
            "delete-forward": buffer.delete_forward,
            "clear-cursors": buffer.clear_cursors,
            "undo": buffer.undo,
            "redo": buffer.redo,
            "print": lambda: out.write(buffer.render()),
        }

    def run(self, command: str) -> None:
        """Execute one command line."""
        simple = self._simple.get(command)
        if simple is not None:
            simple()
            return
        word, _, rest = command.partition(" ")
        if word == "insert" and rest:
            self.buffer.insert(decode_text(rest))
        elif word == "move":
            args = rest.split(" ")
            if len(args) not in (1, 2) or (len(args) == 2 and args[1] != "select"):
                raise CommandError(f"bad move command: {command!r}")
            try:
                direction = Direction(args[0])
            except ValueError:
                raise CommandError(f"unknown direction: {args[0]!r}") from None
            self.buffer.move(direction, len(args) == 2)
        elif word in ("goto", "add-cursor"):
            args = rest.split(" ")
            if len(args) != 2:
                raise CommandError(f"bad {word} command: {command!r}")
            method = self.buffer.goto if word == "goto" else self.buffer.add_cursor
            method(_int(args[0]), _int(args[1]))
        else:
            raise CommandError(f"unknown command: {command!r}")

    def run_all(self, commands: Iterable[str]) -> None:
        for command in commands:
            self.run(command)
