"""Card database loading and validation (SPEC section 5).

:func:`load_database` reads a ``.spire`` file, validates it completely and
returns a :class:`Database`.  Every violation raises :class:`DatabaseError`.
"""

from __future__ import annotations

import re
from typing import Any

from . import sexpr
from .errors import DatabaseError
from .model import (
    CARD_TYPES, EVENTS, KEYWORDS, Ability, Card, is_volatile,
)
from .sexpr import String, Symbol

__all__ = ["Database", "load_database", "parse_database"]

_CARD_ID = re.compile(r"[A-Z]{3}-[0-9]{3}\Z")
_CMPS = frozenset(("le", "lt", "eq", "ge", "gt", "ne"))
_SCOPES = frozenset(("yours", "theirs", "all"))
_ZONES = frozenset(("hand", "ash", "vault", "rift"))
_WHENS = frozenset(("turn-end", "end-of-combat", "your-next-turn-start"))


def _bad(msg: str = "invalid database") -> DatabaseError:
    return DatabaseError(msg)


def _is_int(x: Any) -> bool:
    return type(x) is int


def _is_sym(x: Any) -> bool:
    return type(x) is Symbol


def _head(x: Any) -> tuple[str, list]:
    """Split a form into ``(head symbol, arguments)``."""
    if type(x) is not list or not x or not _is_sym(x[0]):
        raise _bad("expected a form")
    return str(x[0]), x[1:]


def _need(args: list, n: int) -> None:
    if len(args) != n:
        raise _bad("bad arity")


class Database:
    """A validated set of cards, keyed by id."""

    def __init__(self, cards: dict[str, Card]):
        self.cards = cards

    def get(self, card_id: str) -> Card | None:
        return self.cards.get(card_id)

    def __contains__(self, card_id: str) -> bool:
        return card_id in self.cards

    def __len__(self) -> int:
        return len(self.cards)


# --------------------------------------------------------------------------
# Leaf compilers: comparators, keywords, filters, selectors, amounts, ...
# --------------------------------------------------------------------------

class _Compiler:
    """Compiles s-expression forms into the tuple trees the engine walks."""

    def __init__(self) -> None:
        self.card_refs: list[tuple[str, str]] = []   # (op, card id)

    # -- small pieces ------------------------------------------------------
    def cmp(self, x: Any) -> str:
        if not _is_sym(x) or x not in _CMPS:
            raise _bad("bad comparator")
        return str(x)

    def integer(self, x: Any) -> int:
        if not _is_int(x):
            raise _bad("expected integer")
        return x

    def scope(self, x: Any) -> str:
        if not _is_sym(x) or x not in _SCOPES:
            raise _bad("bad scope")
        return str(x)

    def keyword(self, x: Any) -> str:
        if not _is_sym(x) or x not in KEYWORDS:
            raise _bad("unknown keyword")
        return str(x)

    def kwspec(self, x: Any) -> tuple[str, int]:
        if _is_sym(x):
            name = self.keyword(x)
            if name == "plating":
                raise _bad("plating needs a value")
            return (name, 0)
        head, args = _head(x)
        if head != "plating":
            raise _bad("bad keyword spec")
        _need(args, 1)
        return ("plating", self.integer(args[0]))

    def card_type(self, x: Any) -> str:
        if not _is_sym(x) or x not in CARD_TYPES:
            raise _bad("bad type")
        return str(x)

    def symbol(self, x: Any) -> str:
        if not _is_sym(x):
            raise _bad("expected symbol")
        return str(x)

    # -- filters -----------------------------------------------------------
    def filter(self, x: Any) -> tuple:
        head, a = _head(x)
        if head in ("kw", "no-kw"):
            _need(a, 1)
            return (head, self.keyword(a[0]))
        if head == "tag":
            _need(a, 1)
            return ("tag", self.symbol(a[0]))
        if head == "type":
            _need(a, 1)
            return ("type", self.card_type(a[0]))
        if head in ("cost", "edge", "core"):
            _need(a, 2)
            return (head, self.cmp(a[0]), self.integer(a[1]))
        if head in ("wounded", "ready", "exhausted", "settling", "attacking",
                    "blocking", "mine", "enemy", "other"):
            _need(a, 0)
            return (head,)
        if head == "not":
            _need(a, 1)
            return ("not", self.filter(a[0]))
        raise _bad("bad filter")

    def filters(self, xs: list) -> list:
        return [self.filter(f) for f in xs]

    def cardfilter(self, x: Any) -> tuple:
        head, a = _head(x)
        if head == "type":
            _need(a, 1)
            return ("type", self.card_type(a[0]))
        if head == "tag":
            _need(a, 1)
            return ("tag", self.symbol(a[0]))
        if head == "cost":
            _need(a, 2)
            return ("cost", self.cmp(a[0]), self.integer(a[1]))
        raise _bad("bad card filter")

    # -- selectors ---------------------------------------------------------
    def sel(self, x: Any) -> tuple:
        """Object selector."""
        if _is_sym(x):
            if x in ("self", "it", "that"):
                return (str(x),)
            raise _bad("bad selector")
        head, a = _head(x)
        if head == "t":
            _need(a, 1)
            return ("t", self.integer(a[0]))
        if head in ("units", "relics", "random-unit"):
            if not a:
                raise _bad("bad arity")
            return (head, self.scope(a[0]), self.filters(a[1:]))
        if head == "cards":
            if len(a) < 2 or not _is_sym(a[0]) or a[0] not in _ZONES:
                raise _bad("bad cards selector")
            return ("cards", str(a[0]), self.scope(a[1]), self.filters(a[2:]))
        raise _bad("bad selector")

    def psel(self, x: Any) -> tuple:
        """Player selector."""
        if _is_sym(x):
            if x in ("you", "foe", "both"):
                return (str(x),)
            raise _bad("bad player selector")
        head, a = _head(x)
        if head == "t":
            _need(a, 1)
            return ("t", self.integer(a[0]))
        if head == "owner-of":
            _need(a, 1)
            return ("owner-of", self.sel(a[0]))
        raise _bad("bad player selector")

    def dsel(self, x: Any) -> tuple:
        if _is_sym(x) and x in ("you", "foe", "both"):
            return (str(x),)
        if type(x) is list and x and _is_sym(x[0]) and x[0] == "owner-of":
            return self.psel(x)
        return self.sel(x)

    # -- amounts & conditions ---------------------------------------------
    def amt(self, x: Any) -> Any:
        if _is_int(x):
            return x
        head, a = _head(x)
        if head == "count":
            _need(a, 1)
            return ("count", self.sel(a[0]))
        if head in ("hand", "ash", "vault"):
            _need(a, 1)
            return (head, self.psel(a[0]))
        if head in ("edge", "core", "wounds"):
            _need(a, 1)
            return (head, self.sel(a[0]))
        raise _bad("bad amount")

    def cond(self, x: Any) -> tuple:
        head, a = _head(x)
        if head == "count":
            _need(a, 3)
            return ("count", self.sel(a[0]), self.cmp(a[1]), self.integer(a[2]))
        if head in ("spire", "hand", "ash", "vault", "ember"):
            _need(a, 3)
            return (head, self.psel(a[0]), self.cmp(a[1]), self.integer(a[2]))
        if head == "myturn":
            _need(a, 0)
            return ("myturn",)
        if head in ("and", "or"):
            return (head, [self.cond(c) for c in a])
        if head == "not":
            _need(a, 1)
            return ("not", self.cond(a[0]))
        raise _bad("bad condition")

    # -- effects -----------------------------------------------------------
    def effects(self, xs: list) -> list:
        return [self.effect(e) for e in xs]

    def effect_list(self, x: Any) -> list:
        if type(x) is not list:
            raise _bad("expected an effect list")
        return self.effects(x)

    def effect(self, x: Any) -> tuple:
        head, a = _head(x)
        if head == "damage":
            _need(a, 2)
            return ("damage", self.amt(a[0]), self.dsel(a[1]))
        if head in ("destroy", "sacrifice", "exile", "bounce", "ready",
                    "exhaust", "doom", "control", "reanimate", "recall",
                    "swapstats", "strip"):
            _need(a, 1)
            return (head, self.sel(a[0]))
        if head in ("draw", "discard", "mill", "spire", "ember", "cap",
                    "shield"):
            _need(a, 2)
            return (head, self.amt(a[0]), self.psel(a[1]))
        if head in ("modify", "setbody"):
            _need(a, 3)
            return (head, self.amt(a[0]), self.amt(a[1]), self.sel(a[2]))
        if head == "grant":
            _need(a, 2)
            return ("grant", self.kwspec(a[0]), self.sel(a[1]))
        if head in ("counters", "ward"):
            _need(a, 2)
            return (head, self.amt(a[0]), self.sel(a[1]))
        if head in ("summon", "conjure"):
            _need(a, 3)
            cid = self.symbol(a[0])
            self.card_refs.append((head, cid))
            return (head, cid, self.amt(a[1]), self.psel(a[2]))
        if head == "negate":
            _need(a, 1)
            s = self.sel(a[0])
            if s[0] != "t":
                raise _bad("negate needs a target")
            return ("negate", s)
        if head == "dig":
            _need(a, 3)
            if type(a[1]) is not list:
                raise _bad("dig needs a filter list")
            return ("dig", self.integer(a[0]), self.filters(a[1]),
                    self.psel(a[2]))
        if head == "delay":
            if not a or not _is_sym(a[0]) or a[0] not in _WHENS:
                raise _bad("bad delay timing")
            return ("delay", str(a[0]), self.effects(a[1:]))
        if head == "if":
            if len(a) not in (2, 3):
                raise _bad("bad arity")
            then = self.effect_list(a[1])
            other = self.effect_list(a[2]) if len(a) == 3 else None
            return ("if", self.cond(a[0]), then, other)
        if head == "each":
            if not a:
                raise _bad("bad arity")
            return ("each", self.sel(a[0]), self.effects(a[1:]))
        if head == "repeat":
            if not a:
                raise _bad("bad arity")
            return ("repeat", self.amt(a[0]), self.effects(a[1:]))
        if head == "nothing":
            _need(a, 0)
            return ("nothing",)
        raise _bad("unknown effect")

    # -- target specs, cost items, statics --------------------------------
    def tspec(self, x: Any) -> tuple:
        head, a = _head(x)
        if head in ("unit", "relic", "any", "ashcard"):
            return (head, self.filters(a))
        if head in ("player", "chained"):
            _need(a, 0)
            return (head, [])
        raise _bad("bad target spec")

    def costitem(self, x: Any) -> tuple:
        head, a = _head(x)
        if head in ("ember", "spire", "discard", "counters"):
            _need(a, 1)
            return (head, self.integer(a[0]))
        if head in ("exhaust", "sacself", "once"):
            _need(a, 0)
            return (head,)
        raise _bad("bad cost item")

    def static(self, x: Any) -> tuple:
        head, a = _head(x)
        if head in ("modify", "setbody"):
            _need(a, 3)
            return (head, self.amt(a[0]), self.amt(a[1]), self.sel(a[2]))
        if head == "swapstats":
            _need(a, 1)
            return ("swapstats", self.sel(a[0]))
        if head == "grant":
            _need(a, 2)
            return ("grant", self.kwspec(a[0]), self.sel(a[1]))
        if head == "cheaper":
            if not a:
                raise _bad("bad arity")
            return ("cheaper", self.integer(a[0]),
                    [self.cardfilter(f) for f in a[1:]])
        if head == "when":
            if not a:
                raise _bad("bad arity")
            return ("when", self.cond(a[0]), [self.static(s) for s in a[1:]])
        raise _bad("bad static")


# --------------------------------------------------------------------------
# Cards
# --------------------------------------------------------------------------

def _ability_parts(comp: _Compiler, kind: str, parts: list) -> dict:
    cost = targets = None
    raw_cost = raw_targets = None
    effects_raw: list = []
    for part in parts:
        head = str(part[0]) if type(part) is list and part and _is_sym(part[0]) else None
        if head == "cost" and not effects_raw:
            if kind != "act" or cost is not None:
                raise _bad("misplaced cost")
            cost = [comp.costitem(i) for i in part[1:]]
            raw_cost = part
        elif head == "targets" and not effects_raw:
            if targets is not None:
                raise _bad("duplicate targets")
            targets = [comp.tspec(t) for t in part[1:]]
            raw_targets = part
        else:
            effects_raw.append(part)
    if kind == "act" and cost is None:
        raise _bad("act needs a cost")
    if not effects_raw:
        raise _bad("ability has no effects")
    return dict(cost=cost, targets=targets, raw_cost=raw_cost,
                raw_targets=raw_targets, effects=comp.effects(effects_raw),
                raw_effects=effects_raw)


def _compile_card(comp: _Compiler, x: Any) -> Card:
    if type(x) is not list or len(x) < 2 or not _is_sym(x[0]) or x[0] != "card":
        raise _bad("expected (card ...)")
    cid = x[1]
    if not _is_sym(cid) or not _CARD_ID.match(cid):
        raise _bad("bad card id")
    seen: dict[str, int] = {}
    name = ctype = cost = body = None
    tags: tuple = ()
    keywords: tuple = ()
    text = None
    abilities: list[Ability] = []
    pending: list[tuple[str, Any]] = []   # (kind, clause) for numbering
    for clause in x[2:]:
        head, a = _head(clause)
        if head in ("name", "type", "cost", "body", "tags", "keywords", "text",
                    "resolve"):
            seen[head] = seen.get(head, 0) + 1
            if head in ("name", "type", "cost", "body", "tags", "keywords",
                        "text", "resolve") and seen[head] > 1:
                raise _bad("duplicate clause")
        if head == "name":
            _need(a, 1)
            if type(a[0]) is not String:
                raise _bad("name must be a string")
            name = str(a[0])
        elif head == "type":
            _need(a, 1)
            ctype = comp.card_type(a[0])
        elif head == "cost":
            _need(a, 1)
            cost = comp.integer(a[0])
            if cost < 0:
                raise _bad("negative cost")
        elif head == "body":
            _need(a, 2)
            body = (comp.integer(a[0]), comp.integer(a[1]))
            if body[0] < 0 or body[1] < 0:
                raise _bad("negative body")
        elif head == "tags":
            tags = tuple(comp.symbol(t) for t in a)
        elif head == "keywords":
            keywords = tuple(comp.kwspec(k) for k in a)
        elif head == "text":
            _need(a, 1)
            if type(a[0]) is not String:
                raise _bad("text must be a string")
            text = str(a[0])
        elif head in ("resolve", "act", "aura"):
            pending.append((head, clause))
        elif head == "on":
            pending.append((head, clause))
        else:
            raise _bad("unknown clause")
    if name is None or ctype is None or cost is None:
        raise _bad("missing required clause")
    if ctype == "unit" and body is None:
        raise _bad("unit needs a body")
    if ctype != "unit" and body is not None:
        raise _bad("body only on units")
    if ctype == "rite" and "resolve" not in seen:
        raise _bad("rite needs resolve")
    if ctype != "rite" and "resolve" in seen:
        raise _bad("resolve only on rites")
    for k, _ in keywords:
        if k == "swift":
            if ctype != "rite":
                raise _bad("swift only on rites")
        elif ctype != "unit":
            raise _bad("keyword not allowed on this type")
    # Numbering: resolve, on..., act..., aura...
    order = {"resolve": 0, "on": 1, "act": 2, "aura": 3}
    pending.sort(key=lambda p: order[p[0]])   # stable: file order within kind
    for number, (kind, clause) in enumerate(pending, 1):
        a = clause[1:]
        if kind == "aura":
            if not a:
                raise _bad("empty aura")
            statics = [comp.static(s) for s in a]
            abilities.append(Ability(number, "aura", statics=statics,
                                     raw_effects=list(a),
                                     volatile=is_volatile(statics)))
        elif kind == "on":
            if not a or not _is_sym(a[0]) or a[0] not in EVENTS:
                raise _bad("unknown event")
            p = _ability_parts(comp, "on", a[1:])
            abilities.append(Ability(number, "on", event=str(a[0]),
                                     cost=None, targets=p["targets"],
                                     effects=p["effects"],
                                     raw_targets=p["raw_targets"],
                                     raw_effects=p["raw_effects"]))
        else:
            p = _ability_parts(comp, kind, a)
            abilities.append(Ability(number, kind, cost=p["cost"],
                                     targets=p["targets"],
                                     effects=p["effects"],
                                     raw_cost=p["raw_cost"],
                                     raw_targets=p["raw_targets"],
                                     raw_effects=p["raw_effects"]))
    card = Card(id=str(cid), name=name, type=ctype, cost=cost,
                edge=body[0] if body else 0, core=body[1] if body else 0,
                tags=tags, keywords=keywords, text=text, abilities=abilities)
    card.index_abilities()
    return card


def parse_database(text: str) -> Database:
    """Validate database *text* and return the :class:`Database`."""
    forms = sexpr.parse(text)
    comp = _Compiler()
    cards: dict[str, Card] = {}
    for form in forms:
        card = _compile_card(comp, form)
        if card.id in cards:
            raise _bad("duplicate card id")
        cards[card.id] = card
    for op, cid in comp.card_refs:
        target = cards.get(cid)
        if target is None:
            raise _bad("unknown card " + cid)
        if op == "summon" and target.type == "rite":
            raise _bad("cannot summon a rite")
    return Database(cards)


def load_database(path: str) -> Database:
    """Read and validate the database at *path*."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        text = data.decode("utf-8")
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise DatabaseError("cannot read database: %s" % exc) from exc
    return parse_database(text)
