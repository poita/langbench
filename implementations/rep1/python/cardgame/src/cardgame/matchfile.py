"""Match-file parsing: the setup block (SPEC 4.1) and script lines (4.2)."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from .config import Config
from .errors import SetupError

__all__ = ["split_lines", "parse_setup", "parse_script_line", "Command",
           "Action"]

_SPLIT = re.compile(r"[ \t]+")
_DIGITS = re.compile(r"[0-9]+\Z")
_U64 = 1 << 64


def split_lines(text: str) -> list[str]:
    """Split input into lines; a ``\\r`` before ``\\n`` is stripped."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [ln[:-1] if ln.endswith("\r") else ln for ln in lines]


def _words(line: str) -> list[str]:
    """Words of a line; empty for blank and comment lines."""
    stripped = line.strip(" \t")
    if not stripped or stripped[0] == "#":
        return []
    return _SPLIT.split(stripped)


def _bad() -> SetupError:
    return SetupError("bad-setup")


def _number(word: str, lo: int, hi: int) -> int:
    if not _DIGITS.match(word):
        raise _bad()
    value = int(word)
    if not lo <= value <= hi:
        raise _bad()
    return value


def _entries(words: list[str]) -> list[tuple[str, int]]:
    if not words:
        raise _bad()
    out = []
    for w in words:
        if "*" in w:
            cid, _, count = w.partition("*")
            if not cid or "*" in count:
                raise _bad()
            out.append((cid, _number(count, 1, 1000)))
        else:
            out.append((w, 1))
    return out


def parse_setup(lines: list[str]) -> tuple[Config, int]:
    """Parse the setup block.

    Returns the :class:`Config` and the index of the first script line.
    Raises :class:`SetupError` (``bad-setup``) on any violation.
    """
    cfg = Config()
    seen: set[str] = set()
    have_cards = have_seed = False
    for i, line in enumerate(lines):
        w = _words(line)
        if not w:
            continue
        word = w[0]
        if word == "START":
            if len(w) != 1 or not (have_cards and have_seed):
                raise _bad()
            return cfg, i + 1
        if word in ("DECK", "HAND", "FIELD", "ASH", "RIFT"):
            if len(w) < 3 or w[1] not in ("A", "B"):
                raise _bad()
            cfg.zones[word][w[1]].extend(_entries(w[2:]))
            continue
        key = word
        if word == "CAP":
            if len(w) != 3 or w[1] not in ("A", "B"):
                raise _bad()
            key = "CAP " + w[1]
        elif word in ("CARDS", "SEED", "SPIRE", "OPENING", "MAXCAP",
                      "HANDMAX", "TURNLIMIT", "FIRST", "SHUFFLE", "TRACE"):
            if len(w) != 2:
                raise _bad()
        else:
            raise _bad()
        if key in seen:
            raise _bad()
        seen.add(key)
        arg = w[-1]
        if word == "CARDS":
            cfg.cards = arg
            have_cards = True
        elif word == "SEED":
            cfg.seed = _number(arg, 0, _U64 - 1)
            have_seed = True
        elif word == "SPIRE":
            cfg.spire = _number(arg, 1, 1000000)
        elif word == "OPENING":
            cfg.opening = _number(arg, 0, 20)
        elif word == "MAXCAP":
            cfg.maxcap = _number(arg, 1, 100)
        elif word == "HANDMAX":
            cfg.handmax = _number(arg, 0, 100)
        elif word == "TURNLIMIT":
            cfg.turnlimit = _number(arg, 1, 100000)
        elif word == "FIRST":
            if arg not in ("A", "B"):
                raise _bad()
            cfg.first = arg
        elif word == "SHUFFLE":
            if arg not in ("on", "off"):
                raise _bad()
            cfg.shuffle = arg == "on"
        elif word == "TRACE":
            if arg not in ("none", "legal", "state"):
                raise _bad()
            cfg.trace = arg
        else:  # CAP A / CAP B
            cfg.cap[w[1]] = _number(arg, 0, 100)
    raise _bad()


# ---------------------------------------------------------------------------
# Script lines
# ---------------------------------------------------------------------------

@dataclass
class Action:
    """A parsed player action.

    ``kind`` is PASS, CONCEDE, PLAY, ACT, ATTACK or BLOCK.  Target tokens are
    ``('P', 'A'|'B')``, ``('O', oid)`` or ``('E', cid)``.
    """

    kind: str
    player: str
    pos: int = 0
    oid: int = 0
    index: int = 0
    targets: tuple = ()
    objs: tuple = ()          # ATTACK: oids
    pairs: tuple = ()         # BLOCK: (blocker oid, attacker oid)


@dataclass
class Command:
    """A parsed script line: a directive or an action."""

    kind: str                 # DUMP | LEGAL | VAULT | CARD | ACTION
    card_id: str = ""
    action: Action | None = None


def _num(word: str) -> int | None:
    if not _DIGITS.match(word):
        return None
    value = int(word)
    return value if value < _U64 else None


def _objref(word: str) -> int | None:
    if len(word) < 2 or word[0] != "#":
        return None
    return _num(word[1:])


def _target(word: str) -> tuple | None:
    if word in ("A", "B"):
        return ("P", word)
    if len(word) >= 2 and word[0] in "#~":
        n = _num(word[1:])
        if n is not None:
            return ("O" if word[0] == "#" else "E", n)
    return None


def parse_script_line(line: str) -> Command | None | bool:
    """Parse one script line.

    Returns ``False`` for a comment/blank line, ``None`` for a syntax error,
    otherwise a :class:`Command`.
    """
    w = _words(line)
    if not w:
        return False
    head = w[0]
    if head in ("DUMP", "LEGAL", "VAULT"):
        return Command(head) if len(w) == 1 else None
    if head == "CARD":
        return Command("CARD", card_id=w[1]) if len(w) == 2 else None
    if head not in ("A", "B") or len(w) < 2:
        return None
    word = w[1]
    rest = w[2:]
    act: Action | None = None
    if word in ("PASS", "CONCEDE"):
        if not rest:
            act = Action(word, head)
    elif word == "PLAY":
        pos = _num(rest[0]) if rest else None
        if pos is not None:
            targets = [_target(t) for t in rest[1:]]
            if None not in targets:
                act = Action("PLAY", head, pos=pos, targets=tuple(targets))
    elif word == "ACT":
        oid = _objref(rest[0]) if len(rest) >= 2 else None
        idx = _num(rest[1]) if len(rest) >= 2 else None
        if oid is not None and idx is not None:
            targets = [_target(t) for t in rest[2:]]
            if None not in targets:
                act = Action("ACT", head, oid=oid, index=idx,
                             targets=tuple(targets))
    elif word == "ATTACK":
        objs = [_objref(t) for t in rest]
        if None not in objs:
            act = Action("ATTACK", head, objs=tuple(objs))
    elif word == "BLOCK":
        pairs = []
        for t in rest:
            b, sep, a = t.partition(":")
            bo = _objref(b) if sep else None
            ao = _objref(a) if sep else None
            if bo is None or ao is None:
                pairs = None
                break
            pairs.append((bo, ao))
        if pairs is not None:
            act = Action("BLOCK", head, pairs=tuple(pairs))
    if act is None:
        return None
    return Command("ACTION", action=act)
