"""S-expression reader, card model and validator, canonical printer.

Implements SPEC.md sections 5 (card database file) and the grammar of
section 6 (effect language).  A validation failure is reported by raising
BadDatabase; the caller turns that into the single `FATAL bad-database` line.
"""


class BadDatabase(Exception):
    """Raised for any violation of SPEC.md 5.2 / 5.4."""


class Sym:
    """A symbol atom."""

    __slots__ = ("s",)

    def __init__(self, s):
        self.s = s

    def __repr__(self):
        return self.s

    def __eq__(self, other):
        return isinstance(other, Sym) and other.s == self.s

    def __hash__(self):
        return hash(("sym", self.s))


class Str:
    """A string atom.  There are no escapes, so the contents are literal."""

    __slots__ = ("s",)

    def __init__(self, s):
        self.s = s

    def __repr__(self):
        return '"' + self.s + '"'

    def __eq__(self, other):
        return isinstance(other, Str) and other.s == self.s

    def __hash__(self):
        return hash(("str", self.s))


WS = " \t\r\n\f\v"
DELIMS = WS + "();\""
INT64_MIN = -(2 ** 63)
INT64_MAX = 2 ** 63 - 1


def tokenize(text):
    """Split `text` into tokens per SPEC.md 5.1."""
    toks = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in WS:
            i += 1
        elif c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "(" or c == ")":
            toks.append(c)
            i += 1
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 1
            if j >= n or text[j] != '"':
                raise BadDatabase("unterminated string")
            toks.append(Str(text[i + 1:j]))
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in DELIMS:
                j += 1
            atom = text[i:j]
            toks.append(atom_value(atom))
            i = j
    return toks


def is_int_atom(atom):
    body = atom[1:] if atom.startswith("-") else atom
    return len(body) > 0 and all("0" <= ch <= "9" for ch in body)


def atom_value(atom):
    if is_int_atom(atom):
        v = int(atom)
        if v < INT64_MIN or v > INT64_MAX:
            raise BadDatabase("integer out of range")
        return v
    return Sym(atom)


def parse_forms(toks):
    """Turn a token list into a list of top-level forms."""
    pos = 0

    def parse_one():
        nonlocal pos
        if pos >= len(toks):
            raise BadDatabase("unexpected end of file")
        t = toks[pos]
        if t == "(":
            pos += 1
            items = []
            while True:
                if pos >= len(toks):
                    raise BadDatabase("unterminated list")
                if toks[pos] == ")":
                    pos += 1
                    return items
                items.append(parse_one())
        if t == ")":
            raise BadDatabase("stray close paren")
        pos += 1
        return t

    forms = []
    while pos < len(toks):
        forms.append(parse_one())
    return forms


def pr(node):
    """Canonical s-expression printing (SPEC.md 23.4)."""
    if isinstance(node, list):
        return "(" + " ".join(pr(x) for x in node) + ")"
    if isinstance(node, Sym):
        return node.s
    if isinstance(node, Str):
        return '"' + node.s + '"'
    return str(node)


# --------------------------------------------------------------- vocabulary --

KEYWORDS = (
    "vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook",
    "venom", "siphon", "plating", "provoke", "spectral", "tenacity",
    "siegework", "shackled", "relentless", "swift",
)
UNIT_KEYWORDS = frozenset(KEYWORDS) - {"swift"}
RITE_KEYWORDS = frozenset({"swift"})

EVENTS = frozenset((
    "arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies",
    "enemy-dies", "turn-start", "your-turn-start", "turn-end",
    "your-turn-end", "attacks", "blocks", "blocked", "unblocked", "damaged",
    "deals-damage", "you-play-rite", "enemy-plays-rite", "you-draw",
    "spire-loss", "enemy-spire-loss", "end-of-combat",
))

CMPS = frozenset(("le", "lt", "eq", "ge", "gt", "ne"))
SCOPES = frozenset(("yours", "theirs", "all"))
CARD_ZONES = frozenset(("hand", "ash", "vault", "rift"))
TYPES = frozenset(("unit", "rite", "relic"))
DELAY_WHENS = frozenset(("turn-end", "end-of-combat", "your-next-turn-start"))

OBJ_SELECTORS = frozenset(("self", "it", "that"))
NULLARY_FILTERS = frozenset((
    "wounded", "ready", "exhausted", "settling", "attacking", "blocking",
    "mine", "enemy", "other",
))


def sym_name(node):
    return node.s if isinstance(node, Sym) else None


def head(node):
    if isinstance(node, list) and node and isinstance(node[0], Sym):
        return node[0].s
    return None


# --------------------------------------------------------------- validation --

def vfail(msg):
    raise BadDatabase(msg)


def check_int(node):
    if not isinstance(node, int):
        vfail("expected integer")
    return node


def check_sym(node):
    if not isinstance(node, Sym):
        vfail("expected symbol")
    return node.s


def check_filter(node):
    if not isinstance(node, list) or not node:
        vfail("bad filter")
    h = head(node)
    if h is None:
        vfail("bad filter")
    if h in NULLARY_FILTERS:
        if len(node) != 1:
            vfail("bad filter arity")
    elif h in ("kw", "no-kw"):
        if len(node) != 2 or check_sym(node[1]) not in KEYWORDS:
            vfail("bad keyword filter")
    elif h == "tag":
        if len(node) != 2:
            vfail("bad tag filter")
        check_sym(node[1])
    elif h == "type":
        if len(node) != 2 or check_sym(node[1]) not in TYPES:
            vfail("bad type filter")
    elif h in ("cost", "edge", "core"):
        if len(node) != 3 or check_sym(node[1]) not in CMPS:
            vfail("bad numeric filter")
        check_int(node[2])
    elif h == "not":
        if len(node) != 2:
            vfail("bad not filter")
        check_filter(node[1])
    else:
        vfail("unknown filter " + h)


def check_selector(node):
    """An object selector (SPEC.md 6.3)."""
    if isinstance(node, Sym):
        if node.s not in OBJ_SELECTORS:
            vfail("unknown selector " + node.s)
        return
    if not isinstance(node, list) or not node:
        vfail("bad selector")
    h = head(node)
    if h == "t":
        if len(node) != 2:
            vfail("bad (t n)")
        check_int(node[1])
    elif h in ("units", "relics", "random-unit"):
        if len(node) < 2 or check_sym(node[1]) not in SCOPES:
            vfail("bad scope")
        for f in node[2:]:
            check_filter(f)
    elif h == "cards":
        if len(node) < 3:
            vfail("bad (cards ...)")
        if check_sym(node[1]) not in CARD_ZONES:
            vfail("bad card zone")
        if check_sym(node[2]) not in SCOPES:
            vfail("bad scope")
        for f in node[3:]:
            check_filter(f)
    else:
        vfail("unknown selector")


def check_psel(node):
    """A player selector (SPEC.md 6.4)."""
    if isinstance(node, Sym):
        if node.s not in ("you", "foe", "both"):
            vfail("unknown player selector " + node.s)
        return
    if not isinstance(node, list) or not node:
        vfail("bad player selector")
    h = head(node)
    if h == "t":
        if len(node) != 2:
            vfail("bad (t n)")
        check_int(node[1])
    elif h == "owner-of":
        if len(node) != 2:
            vfail("bad owner-of")
        check_selector(node[1])
    else:
        vfail("unknown player selector")


def check_dsel(node):
    """A damage selector (SPEC.md 6.4.1): object or player selector."""
    if isinstance(node, Sym):
        if node.s in ("you", "foe", "both") or node.s in OBJ_SELECTORS:
            return
        vfail("unknown damage selector " + node.s)
    if not isinstance(node, list) or not node:
        vfail("bad damage selector")
    if head(node) == "owner-of":
        check_psel(node)
    else:
        check_selector(node)


def check_amount(node):
    if isinstance(node, int):
        return
    if not isinstance(node, list) or not node:
        vfail("bad amount")
    h = head(node)
    if h == "count":
        if len(node) != 2:
            vfail("bad (count ...)")
        check_selector(node[1])
    elif h in ("hand", "ash", "vault"):
        if len(node) != 2:
            vfail("bad amount")
        check_psel(node[1])
    elif h in ("edge", "core", "wounds"):
        if len(node) != 2:
            vfail("bad amount")
        check_selector(node[1])
    else:
        vfail("unknown amount " + str(h))


def check_cond(node):
    if not isinstance(node, list) or not node:
        vfail("bad condition")
    h = head(node)
    if h == "count":
        if len(node) != 4:
            vfail("bad (count ...) condition")
        check_selector(node[1])
        if check_sym(node[2]) not in CMPS:
            vfail("bad cmp")
        check_int(node[3])
    elif h in ("spire", "hand", "ash", "vault", "ember"):
        if len(node) != 4:
            vfail("bad condition")
        check_psel(node[1])
        if check_sym(node[2]) not in CMPS:
            vfail("bad cmp")
        check_int(node[3])
    elif h == "myturn":
        if len(node) != 1:
            vfail("bad (myturn)")
    elif h in ("and", "or"):
        for c in node[1:]:
            check_cond(c)
    elif h == "not":
        if len(node) != 2:
            vfail("bad (not ...)")
        check_cond(node[1])
    else:
        vfail("unknown condition " + str(h))


def check_kwspec(node):
    """A keyword specification: a bare keyword or `(plating n)`."""
    if isinstance(node, Sym):
        if node.s not in KEYWORDS or node.s == "plating":
            vfail("bad keyword spec")
        return (node.s, 0)
    if isinstance(node, list) and head(node) == "plating" and len(node) == 2:
        return ("plating", check_int(node[1]))
    vfail("bad keyword spec")


def check_effect_list(nodes):
    if not isinstance(nodes, list):
        vfail("expected effect list")
    for e in nodes:
        check_effect(e)


# Effects taking exactly one object selector.
SEL_EFFECTS = frozenset((
    "destroy", "sacrifice", "exile", "bounce", "swapstats", "strip",
    "control", "ready", "exhaust", "doom", "reanimate", "recall",
))
# Effects taking (amt, psel).
AMT_PSEL_EFFECTS = frozenset(("draw", "discard", "mill", "spire", "ember", "cap", "shield"))


def check_effect(node):
    if not isinstance(node, list) or not node:
        vfail("bad effect")
    h = head(node)
    if h is None:
        vfail("bad effect")
    if h == "damage":
        if len(node) != 3:
            vfail("bad damage")
        check_amount(node[1])
        check_dsel(node[2])
    elif h in SEL_EFFECTS:
        if len(node) != 2:
            vfail("bad effect arity " + h)
        check_selector(node[1])
    elif h in AMT_PSEL_EFFECTS:
        if len(node) != 3:
            vfail("bad effect arity " + h)
        check_amount(node[1])
        check_psel(node[2])
    elif h in ("modify", "setbody"):
        if len(node) != 4:
            vfail("bad " + h)
        check_amount(node[1])
        check_amount(node[2])
        check_selector(node[3])
    elif h == "grant":
        if len(node) != 3:
            vfail("bad grant")
        check_kwspec(node[1])
        check_selector(node[2])
    elif h in ("counters", "ward"):
        if len(node) != 3:
            vfail("bad " + h)
        check_amount(node[1])
        check_selector(node[2])
    elif h in ("summon", "conjure"):
        if len(node) != 4:
            vfail("bad " + h)
        check_sym(node[1])
        check_amount(node[2])
        check_psel(node[3])
    elif h == "negate":
        if len(node) != 2 or head(node[1]) != "t" or len(node[1]) != 2:
            vfail("negate needs a (t n) selector")
        check_int(node[1][1])
    elif h == "dig":
        if len(node) != 4:
            vfail("bad dig")
        check_int(node[1])
        if not isinstance(node[2], list):
            vfail("bad dig filters")
        for f in node[2]:
            check_filter(f)
        check_psel(node[3])
    elif h == "delay":
        if len(node) < 3:
            vfail("bad delay")
        if check_sym(node[1]) not in DELAY_WHENS:
            vfail("bad delay when")
        check_effect_list(node[2:])
    elif h == "if":
        if len(node) not in (3, 4):
            vfail("bad if")
        check_cond(node[1])
        check_effect_list(node[2])
        if len(node) == 4:
            check_effect_list(node[3])
    elif h == "each":
        if len(node) < 3:
            vfail("bad each")
        check_selector(node[1])
        check_effect_list(node[2:])
    elif h == "repeat":
        if len(node) < 3:
            vfail("bad repeat")
        check_amount(node[1])
        check_effect_list(node[2:])
    elif h == "nothing":
        if len(node) != 1:
            vfail("bad nothing")
    else:
        vfail("unknown effect " + h)


def check_cardfilter(node):
    if not isinstance(node, list) or not node:
        vfail("bad card filter")
    h = head(node)
    if h == "type":
        if len(node) != 2 or check_sym(node[1]) not in TYPES:
            vfail("bad card filter")
    elif h == "tag":
        if len(node) != 2:
            vfail("bad card filter")
        check_sym(node[1])
    elif h == "cost":
        if len(node) != 3 or check_sym(node[1]) not in CMPS:
            vfail("bad card filter")
        check_int(node[2])
    else:
        vfail("unknown card filter " + str(h))


def check_static(node):
    if not isinstance(node, list) or not node:
        vfail("bad static")
    h = head(node)
    if h in ("modify", "setbody"):
        if len(node) != 4:
            vfail("bad static " + h)
        check_amount(node[1])
        check_amount(node[2])
        check_selector(node[3])
    elif h == "swapstats":
        if len(node) != 2:
            vfail("bad swapstats static")
        check_selector(node[1])
    elif h == "grant":
        if len(node) != 3:
            vfail("bad grant static")
        check_kwspec(node[1])
        check_selector(node[2])
    elif h == "cheaper":
        if len(node) < 2:
            vfail("bad cheaper")
        check_int(node[1])
        for f in node[2:]:
            check_cardfilter(f)
    elif h == "when":
        if len(node) < 3:
            vfail("bad when")
        check_cond(node[1])
        for s in node[2:]:
            check_static(s)
    else:
        vfail("unknown static " + str(h))


def check_tspec(node):
    if not isinstance(node, list) or not node:
        vfail("bad target spec")
    h = head(node)
    if h in ("unit", "relic", "any", "ashcard"):
        for f in node[1:]:
            check_filter(f)
    elif h in ("player", "chained"):
        if len(node) != 1:
            vfail("bad target spec")
    else:
        vfail("unknown target spec " + str(h))


COSTITEM_INT = frozenset(("ember", "spire", "discard", "counters"))
COSTITEM_NULL = frozenset(("exhaust", "sacself", "once"))


def check_costitem(node):
    if not isinstance(node, list) or not node:
        vfail("bad cost item")
    h = head(node)
    if h in COSTITEM_INT:
        if len(node) != 2:
            vfail("bad cost item " + h)
        check_int(node[1])
    elif h in COSTITEM_NULL:
        if len(node) != 1:
            vfail("bad cost item " + h)
    else:
        vfail("unknown cost item " + str(h))


# ------------------------------------------------------------- card objects --

class Ability:
    __slots__ = ("index", "kind", "event", "cost", "targets", "effects",
                 "statics", "once")

    def __init__(self, index, kind):
        self.index = index
        self.kind = kind          # 'resolve' | 'on' | 'act' | 'aura'
        self.event = None
        self.cost = None          # the raw (cost ...) node, for 'act'
        self.targets = None       # the raw (targets ...) node, or None
        self.effects = []         # list of raw effect nodes
        self.statics = []         # list of raw static nodes, for 'aura'

    def render(self):
        tspec = pr(self.targets) if self.targets is not None else "-"
        if self.kind == "resolve":
            parts = ["resolve", tspec]
        elif self.kind == "on":
            parts = ["on", self.event, tspec]
        elif self.kind == "act":
            parts = ["act", pr(self.cost), tspec]
        else:
            return "aura " + " ".join(pr(s) for s in self.statics)
        parts.extend(pr(e) for e in self.effects)
        return " ".join(parts)

    @property
    def tspecs(self):
        return [] if self.targets is None else self.targets[1:]

    @property
    def costitems(self):
        return [] if self.cost is None else self.cost[1:]


class Card:
    __slots__ = ("cid", "name", "type", "cost", "edge", "core", "tags",
                 "keywords", "text", "abilities")

    def __init__(self, cid):
        self.cid = cid
        self.name = None
        self.type = None
        self.cost = None
        self.edge = 0
        self.core = 0
        self.tags = []
        self.keywords = []        # list of (name, value) in file order
        self.text = None
        self.abilities = []

    def has_printed_kw(self, name):
        return any(k == name for k, _ in self.keywords)

    def keywords_rendered(self):
        return [render_kw(k, v) for k, v in self.keywords]


def render_kw(name, value):
    return "plating:%d" % value if name == "plating" else name


def valid_cardid(s):
    if len(s) != 7 or s[3] != "-":
        return False
    return all("A" <= c <= "Z" for c in s[:3]) and all("0" <= c <= "9" for c in s[4:])


def parse_card(form):
    if not isinstance(form, list) or len(form) < 2 or head(form) != "card":
        vfail("not a card form")
    cid = check_sym(form[1])
    if not valid_cardid(cid):
        vfail("bad card id " + cid)
    card = Card(cid)
    seen = {}
    ons, acts, auras = [], [], []
    resolve = None
    for clause in form[2:]:
        if not isinstance(clause, list) or not clause:
            vfail("bad clause")
        h = head(clause)
        if h is None:
            vfail("bad clause")
        if h == "name":
            if len(clause) != 2 or not isinstance(clause[1], Str):
                vfail("bad name")
            seen["name"] = seen.get("name", 0) + 1
            card.name = clause[1].s
        elif h == "type":
            if len(clause) != 2 or check_sym(clause[1]) not in TYPES:
                vfail("bad type")
            seen["type"] = seen.get("type", 0) + 1
            card.type = clause[1].s
        elif h == "cost":
            if len(clause) != 2:
                vfail("bad cost")
            seen["cost"] = seen.get("cost", 0) + 1
            card.cost = check_int(clause[1])
        elif h == "body":
            if len(clause) != 3:
                vfail("bad body")
            seen["body"] = seen.get("body", 0) + 1
            card.edge = check_int(clause[1])
            card.core = check_int(clause[2])
        elif h == "tags":
            seen["tags"] = seen.get("tags", 0) + 1
            card.tags = [check_sym(t) for t in clause[1:]]
        elif h == "keywords":
            seen["keywords"] = seen.get("keywords", 0) + 1
            card.keywords = [check_kwspec(k) for k in clause[1:]]
        elif h == "text":
            if len(clause) != 2 or not isinstance(clause[1], Str):
                vfail("bad text")
            seen["text"] = seen.get("text", 0) + 1
            card.text = clause[1].s
        elif h == "resolve":
            seen["resolve"] = seen.get("resolve", 0) + 1
            resolve = clause
        elif h == "on":
            if len(clause) < 2 or check_sym(clause[1]) not in EVENTS:
                vfail("bad on event")
            ons.append(clause)
        elif h == "act":
            acts.append(clause)
        elif h == "aura":
            auras.append(clause)
        else:
            vfail("unknown clause " + h)
    for req in ("name", "type", "cost"):
        if seen.get(req, 0) != 1:
            vfail("clause " + req + " must appear exactly once")
    for opt in ("tags", "keywords", "text"):
        if seen.get(opt, 0) > 1:
            vfail("clause " + opt + " repeated")
    if card.cost < 0:
        vfail("negative cost")
    if card.type == "unit":
        if seen.get("body", 0) != 1:
            vfail("unit needs exactly one body")
        if card.edge < 0 or card.core < 0:
            vfail("negative body")
    elif seen.get("body", 0) != 0:
        vfail("body on a non-unit")
    if card.type == "rite":
        if seen.get("resolve", 0) != 1:
            vfail("rite needs exactly one resolve")
    elif seen.get("resolve", 0) != 0:
        vfail("resolve on a non-rite")

    allowed = (UNIT_KEYWORDS if card.type == "unit"
               else RITE_KEYWORDS if card.type == "rite" else frozenset())
    for name, _ in card.keywords:
        if name not in allowed:
            vfail("keyword " + name + " not allowed on a " + card.type)

    index = 0
    if resolve is not None:
        index += 1
        card.abilities.append(build_ability(index, "resolve", resolve))
    for clause in ons:
        index += 1
        ab = build_ability(index, "on", clause, skip=2)
        ab.event = clause[1].s
        card.abilities.append(ab)
    for clause in acts:
        index += 1
        card.abilities.append(build_ability(index, "act", clause))
    for clause in auras:
        index += 1
        ab = Ability(index, "aura")
        if len(clause) < 2:
            vfail("aura needs at least one static")
        for s in clause[1:]:
            check_static(s)
            ab.statics.append(s)
        card.abilities.append(ab)
    return card


def build_ability(index, kind, clause, skip=1):
    ab = Ability(index, kind)
    parts = clause[skip:]
    i = 0
    while i < len(parts):
        h = head(parts[i])
        if h == "cost":
            if kind != "act":
                vfail("cost outside act")
            if ab.cost is not None:
                vfail("duplicate cost")
            if ab.targets is not None or ab.effects:
                vfail("cost must precede targets and effects")
            for ci in parts[i][1:]:
                check_costitem(ci)
            ab.cost = parts[i]
            i += 1
        elif h == "targets":
            if ab.targets is not None:
                vfail("duplicate targets")
            if ab.effects:
                vfail("targets must precede effects")
            if len(parts[i]) < 2:
                vfail("empty targets clause")
            for ts in parts[i][1:]:
                check_tspec(ts)
            ab.targets = parts[i]
            i += 1
        else:
            break
    for node in parts[i:]:
        if head(node) in ("cost", "targets"):
            vfail("cost/targets after an effect")
        check_effect(node)
        ab.effects.append(node)
    if kind == "act" and ab.cost is None:
        vfail("act needs a cost clause")
    if not ab.effects:
        vfail("ability needs at least one effect")
    return ab


def collect_named_cards(node, out, kinds):
    """Record every (effect-kind, cardid) pair of `summon`/`conjure` forms."""
    if isinstance(node, list):
        h = head(node)
        if h in kinds and len(node) == 4 and isinstance(node[1], Sym):
            out.append((h, node[1].s))
        for x in node:
            collect_named_cards(x, out, kinds)


def load_database(path):
    """Read and validate the card database.  Returns {cardid: Card}."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        raise BadDatabase("cannot read database")
    except UnicodeDecodeError:
        raise BadDatabase("database is not UTF-8")
    forms = parse_forms(tokenize(text))
    db = {}
    for form in forms:
        card = parse_card(form)
        if card.cid in db:
            vfail("duplicate card id " + card.cid)
        db[card.cid] = card
    named = []
    for card in db.values():
        for ab in card.abilities:
            collect_named_cards(ab.effects, named, ("summon", "conjure"))
            collect_named_cards(ab.statics, named, ("summon", "conjure"))
    for kind, cid in named:
        if cid not in db:
            vfail("unknown card named by " + kind)
        if kind == "summon" and db[cid].type == "rite":
            vfail("summon names a rite")
    return db


def card_block(db, cid):
    """The lines of a `CARD <cardid>` inspection block (SPEC.md 23.4)."""
    lines = ["CARD BEGIN " + cid]
    card = db.get(cid)
    if card is None:
        lines.append("unknown")
        lines.append("CARD END")
        return lines
    lines.append("name " + card.name)
    lines.append("type " + card.type)
    lines.append("cost %d" % card.cost)
    if card.type == "unit":
        lines.append("body %d/%d" % (card.edge, card.core))
    lines.append("tags " + (",".join(card.tags) if card.tags else "-"))
    kws = sorted(card.keywords_rendered())
    lines.append("keywords " + (",".join(kws) if kws else "-"))
    for ab in card.abilities:
        lines.append("ability %d %s" % (ab.index, ab.render()))
    lines.append("CARD END")
    return lines
