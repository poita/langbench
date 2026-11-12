"""Game objects: players, card objects, chain entries and records."""

from __future__ import annotations

from collections import deque
from typing import Any

from .model import Card


class Player:
    """One of the two players (SPEC 7.1)."""

    __slots__ = ("idx", "name", "spire", "ember", "cap", "shield", "vault",
                 "hand", "ash", "rift", "lost", "opp")

    def __init__(self, idx: int, spire: int, cap: int):
        self.idx = idx
        self.name = "AB"[idx]
        self.spire = spire
        self.ember = 0
        self.cap = cap
        self.shield = 0
        self.vault: deque = deque()
        self.hand: list = []
        self.ash: list = []
        self.rift: list = []
        self.lost: str | None = None
        self.opp: Player = self  # patched by Game

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "Player(%s)" % self.name

    def zone(self, name: str):
        return getattr(self, name)


class Obj:
    """A card instance (SPEC 7.3)."""

    __slots__ = ("oid", "card", "owner", "zone", "ts", "ctrl", "wounds",
                 "counters", "ward", "doomed", "since", "ready", "attacking",
                 "blocking", "blocked", "blockers", "blocking_of",
                 "tenacity_used", "once")

    def __init__(self, oid: int, card: Card, owner: Player, zone: str):
        self.oid = oid
        self.card = card
        self.owner = owner
        self.zone = zone
        self.ts = 0
        self.ctrl = owner      # base controller on the Field, last one off it
        self.reset_field_state(0)

    def reset_field_state(self, since: int) -> None:
        self.wounds = 0
        self.counters = 0
        self.ward = 0
        self.doomed = False
        self.since = since
        self.ready = True
        self.attacking = False
        self.blocking = False
        self.blocked = False
        self.blockers: list[Obj] = []
        self.blocking_of: Obj | None = None
        self.tenacity_used = False
        self.once: set[int] = set()

    @property
    def key(self) -> tuple:
        """Canonical order / target key of an object."""
        return (1, self.ts, self.oid)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "Obj(#%d %s)" % (self.oid, self.card.id)


class Entry:
    """A Chain entry (SPEC 10.1)."""

    __slots__ = ("cid", "kind", "ctrl", "source", "index", "targets",
                 "removed", "tspecs", "effects", "subject")

    def __init__(self, cid: int, kind: str, ctrl: Player, source: Obj,
                 index: int, targets: list, tspecs: list,
                 effects: list | None = None, subject: Any = None):
        self.cid = cid
        self.kind = kind
        self.ctrl = ctrl
        self.source = source
        self.index = index
        self.targets = targets
        self.removed = [False] * len(targets)
        self.tspecs = tspecs
        self.effects = effects
        self.subject = subject

    @property
    def key(self) -> tuple:
        return (2, self.cid, 0)


class Record:
    """A continuous-effect record (SPEC 14.1)."""

    __slots__ = ("eid", "ts", "ctrl", "source", "kind", "args", "duration",
                 "affected", "statics", "leaves", "volatile")

    def __init__(self, eid: int, ts: int, ctrl: Player, source: Obj,
                 kind: str, args: Any, duration: str,
                 affected: list | None = None, statics: list | None = None,
                 volatile: bool = False):
        self.eid = eid
        self.ts = ts
        self.ctrl = ctrl
        self.source = source
        self.kind = kind
        self.args = args
        self.duration = duration
        self.affected = affected or []
        self.statics = statics or []
        self.leaves: list = []
        self.volatile = volatile


class Delayed:
    """A delayed trigger record (SPEC 13.5)."""

    __slots__ = ("ts", "ctrl", "when", "source", "targets", "tspecs",
                 "effects")

    def __init__(self, ts: int, ctrl: Player, when: str, source: Obj,
                 targets: list, tspecs: list, effects: list):
        self.ts = ts
        self.ctrl = ctrl
        self.when = when
        self.source = source
        self.targets = targets
        self.tspecs = tspecs
        self.effects = effects


class Pending:
    """A collected, not yet pushed trigger."""

    __slots__ = ("ctrl", "source", "ability", "subject", "ts", "delayed")

    def __init__(self, ctrl: Player, source: Obj, ability, subject: Any,
                 ts: int, delayed: Delayed | None = None):
        self.ctrl = ctrl
        self.source = source
        self.ability = ability
        self.subject = subject
        self.ts = ts
        self.delayed = delayed


def target_key(t: Any) -> tuple:
    """The target key of a player, object or chain entry (SPEC 12.4)."""
    if isinstance(t, Player):
        return (0, t.idx, 0)
    return t.key


def render_target(t: Any) -> str:
    if isinstance(t, Player):
        return t.name
    if isinstance(t, Obj):
        return "#%d" % t.oid
    return "~%d" % t.cid
