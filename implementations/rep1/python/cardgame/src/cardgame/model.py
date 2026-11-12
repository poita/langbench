"""Typed card definitions produced by :mod:`cardgame.database`.

Effects, selectors, filters, amounts, conditions and statics are stored as
plain tuples ``(op, arg, ...)`` that the interpreter dispatches on.  The
original s-expressions are kept next to them so that the ``CARD`` directive can
print an ability exactly as the database wrote it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

KEYWORDS = (
    "vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook", "venom",
    "siphon", "plating", "provoke", "spectral", "tenacity", "siegework",
    "shackled", "relentless", "swift",
)
UNIT_ONLY_KEYWORDS = frozenset(KEYWORDS) - {"swift"}

EVENTS = (
    "arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies",
    "enemy-dies", "turn-start", "your-turn-start", "turn-end", "your-turn-end",
    "attacks", "blocks", "blocked", "unblocked", "damaged", "deals-damage",
    "you-play-rite", "enemy-plays-rite", "you-draw", "spire-loss",
    "enemy-spire-loss", "end-of-combat",
)

CARD_TYPES = ("unit", "rite", "relic")


@dataclass(eq=False)
class Ability:
    """One numbered ability of a card (SPEC 5.3)."""

    number: int
    kind: str                      # 'resolve' | 'on' | 'act' | 'aura'
    event: str | None = None       # for 'on'
    cost: list | None = None       # compiled cost items (act)
    targets: list | None = None    # compiled target specs, or None
    effects: list = field(default_factory=list)
    statics: list = field(default_factory=list)
    raw_cost: Any = None
    raw_targets: Any = None
    raw_effects: list = field(default_factory=list)
    volatile: bool = False         # aura reads state that changes without a
                                   # Field/record/counter change (see below)


_VOLATILE_HEADS = frozenset((
    "wounded", "ready", "exhausted", "settling", "attacking", "blocking",
    "wounds", "hand", "ash", "vault", "spire", "ember", "myturn", "cards",
    "random-unit",
))


def is_volatile(node) -> bool:
    """True if evaluating *node* can depend on wounds, readiness, combat
    status, zone sizes, Spire, Ember or the turn.

    Auras that are not volatile only need re-deriving after a structural
    change (an object entering or leaving the Field, a counter or a record
    changing), which is what lets the engine cache derivations cheaply.
    """
    if isinstance(node, tuple):
        if node and node[0] in _VOLATILE_HEADS:
            return True
        return any(is_volatile(n) for n in node)
    if isinstance(node, list):
        return any(is_volatile(n) for n in node)
    return False


@dataclass(eq=False)
class Card:
    """A card definition from the database."""

    id: str
    name: str
    type: str
    cost: int
    edge: int = 0
    core: int = 0
    tags: tuple = ()
    keywords: tuple = ()           # ((name, value), ...) as printed
    text: str | None = None
    abilities: list = field(default_factory=list)

    def __post_init__(self) -> None:
        self.kw_names = frozenset(k for k, _ in self.keywords)
        self.tagset = frozenset(self.tags)
        self.is_swift = "swift" in self.kw_names
        self.resolve: Ability | None = None
        self.on: dict[str, list[Ability]] = {}
        self.acts: dict[int, Ability] = {}
        self.auras: list[Ability] = []

    def index_abilities(self) -> None:
        """Build the lookup tables used by the engine."""
        for ab in self.abilities:
            if ab.kind == "resolve":
                self.resolve = ab
            elif ab.kind == "on":
                self.on.setdefault(ab.event, []).append(ab)
            elif ab.kind == "act":
                self.acts[ab.number] = ab
            else:
                self.auras.append(ab)


def render_keyword(name: str, value: int) -> str:
    """Render a keyword instance: ``plating:N`` or the bare name."""
    return "plating:%d" % value if name == "plating" else name
