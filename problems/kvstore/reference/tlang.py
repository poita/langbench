"""The command language: the lexer of SPEC.md §6.1 and the parser of §6.3–§6.5
and §17.1, with the error staging of §18.2.

`lex` raises `syntax` for anything lexically malformed. The parser resolves each
token's value as it consumes it, so the first problem in source order is the one
reported.
"""

import string

import tvalue as V
from tengine import TessError

MAX_LIMIT = 2147483647

COMMANDS = frozenset(["begin", "commit", "rollback", "checkpoint", "stat",
                      "indexes", "put", "get", "delete", "update", "unset",
                      "scan", "find", "create", "drop"])

WORD_START = frozenset(string.ascii_letters + "_")
WORD_CHAR = frozenset(string.ascii_letters + string.digits + "_")
DIGITS = frozenset(string.digits)
PUNCT = frozenset("{}[](),:.")
HEX = frozenset(string.hexdigits)

T_WORD = "W"
T_INT = "I"
T_STR = "S"
T_PUNCT = "P"
T_OP = "O"

_SIMPLE_ESCAPES = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f",
                   "n": "\n", "r": "\r", "t": "\t"}


def _syntax():
    raise TessError("syntax")


def lex(line):
    """Turn one command line into a token list (§6.1)."""
    toks = []
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == " " or ch == "\t":
            i += 1
            continue
        if ch in WORD_START:
            j = i + 1
            while j < n and line[j] in WORD_CHAR:
                j += 1
            toks.append((T_WORD, line[i:j]))
            i = j
            continue
        if ch in DIGITS or (ch == "-" and i + 1 < n and line[i + 1] in DIGITS):
            neg = ch == "-"
            j = i + 1 if neg else i
            while j < n and line[j] in DIGITS:
                j += 1
            digits = line[i + 1:j] if neg else line[i:j]
            if len(digits) > 1 and digits[0] == "0":
                _syntax()
            if neg and digits == "0":
                _syntax()
            toks.append((T_INT, line[i:j]))
            i = j
            continue
        if ch == '"':
            units, i = _lex_string(line, i)
            toks.append((T_STR, units))
            continue
        if ch in PUNCT:
            toks.append((T_PUNCT, ch))
            i += 1
            continue
        if ch == "=" or ch == "!":
            if i + 1 < n and line[i + 1] == "=":
                toks.append((T_OP, ch + "="))
                i += 2
                continue
            _syntax()
        if ch == "<" or ch == ">":
            if i + 1 < n and line[i + 1] == "=":
                toks.append((T_OP, ch + "="))
                i += 2
            else:
                toks.append((T_OP, ch))
                i += 1
            continue
        _syntax()
    return toks


def _lex_string(line, i):
    """Read a string literal, returning its units and the offset past it.

    A unit is either a chunk of literal text or an integer UTF-16 code unit
    from a \\uXXXX escape; surrogate pairing is resolved later, at parse time,
    so that a lexically fine literal yields `bad-utf8` rather than `syntax`.
    """
    n = len(line)
    i += 1
    units = []
    lit = []
    while True:
        if i >= n:
            _syntax()
        ch = line[i]
        if ch == '"':
            i += 1
            break
        if ord(ch) < 0x20:
            _syntax()
        if ch == "\\":
            if i + 1 >= n:
                _syntax()
            esc = line[i + 1]
            if esc in _SIMPLE_ESCAPES:
                lit.append(_SIMPLE_ESCAPES[esc])
                i += 2
                continue
            if esc == "u":
                if i + 6 > n:
                    _syntax()
                digits = line[i + 2:i + 6]
                if len(digits) != 4 or any(d not in HEX for d in digits):
                    _syntax()
                if lit:
                    units.append("".join(lit))
                    lit = []
                units.append(int(digits, 16))
                i += 6
                continue
            _syntax()
        lit.append(ch)
        i += 1
    if lit:
        units.append("".join(lit))
    return units, i


def resolve_string(units):
    """Turn a string token's units into UTF-8 bytes (§6.1)."""
    out = []
    i = 0
    n = len(units)
    while i < n:
        u = units[i]
        if not isinstance(u, int):
            out.append(u)
            i += 1
            continue
        if 0xD800 <= u <= 0xDBFF:
            if i + 1 < n and isinstance(units[i + 1], int) and 0xDC00 <= units[i + 1] <= 0xDFFF:
                lo = units[i + 1]
                out.append(chr(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)))
                i += 2
                continue
            raise TessError("bad-utf8")
        if 0xDC00 <= u <= 0xDFFF:
            raise TessError("bad-utf8")
        out.append(chr(u))
        i += 1
    return "".join(out).encode("utf-8", "surrogateescape")


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

class Command(object):
    __slots__ = ("name", "key", "value", "segs", "path", "frm", "to", "limit",
                 "reverse", "keys", "pred")

    def __init__(self, name):
        self.name = name
        self.key = None
        self.value = None
        self.segs = None
        self.path = None
        self.frm = None
        self.to = None
        self.limit = None
        self.reverse = False
        self.keys = False
        self.pred = None


class Parser(object):
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0

    # ---- token helpers ---------------------------------------------------

    def peek(self, ahead=0):
        i = self.pos + ahead
        if i < len(self.toks):
            return self.toks[i]
        return None

    def next(self):
        t = self.peek()
        if t is None:
            _syntax()
        self.pos += 1
        return t

    def at_end(self):
        return self.pos >= len(self.toks)

    def expect_punct(self, ch):
        t = self.peek()
        if t is None or t[0] != T_PUNCT or t[1] != ch:
            _syntax()
        self.pos += 1

    def at_punct(self, ch):
        t = self.peek()
        return t is not None and t[0] == T_PUNCT and t[1] == ch

    def at_word(self, text, ahead=0):
        t = self.peek(ahead)
        return t is not None and t[0] == T_WORD and t[1] == text

    def take_int(self):
        """An INT token's value, range-checked as signed 64-bit (§6.3)."""
        t = self.peek()
        if t is None or t[0] != T_INT:
            _syntax()
        self.pos += 1
        value = int(t[1])
        if value < V.INT_MIN or value > V.INT_MAX:
            raise TessError("int-range")
        return value

    def take_string(self):
        t = self.peek()
        if t is None or t[0] != T_STR:
            _syntax()
        self.pos += 1
        return resolve_string(t[1])

    def take_key(self):
        """A key argument of put / get / delete / update / unset (§5.1)."""
        b = self.take_string()
        if len(b) < 1 or len(b) > V.MAX_KEY:
            raise TessError("bad-key")
        return b

    def take_limit(self):
        value = self.take_int()
        if value < 0 or value > MAX_LIMIT:
            _syntax()
        return value

    def take_path(self):
        """A field path; its segments and its text (§6.4)."""
        t = self.peek()
        if t is None or t[0] != T_WORD:
            _syntax()
        self.pos += 1
        segs = [t[1].encode("ascii")]
        size = len(segs[0])
        if size > V.MAX_PATH:
            raise TessError("bad-path")
        while self.at_punct("."):
            self.pos += 1
            t = self.peek()
            if t is None or t[0] != T_WORD:
                _syntax()
            self.pos += 1
            seg = t[1].encode("ascii")
            segs.append(seg)
            size += 1 + len(seg)
            if len(segs) > V.MAX_PATH_SEGMENTS or size > V.MAX_PATH:
                raise TessError("bad-path")
        return segs, b".".join(segs)

    # ---- value literals (§6.3) -------------------------------------------

    def take_value(self, level):
        if level > V.MAX_DEPTH:
            raise TessError("depth")
        t = self.peek()
        if t is None:
            _syntax()
        kind, text = t[0], t[1]
        if kind == T_WORD:
            self.pos += 1
            if text == "null":
                return V.VNULL
            if text == "true":
                return V.VTRUE
            if text == "false":
                return V.VFALSE
            _syntax()
        if kind == T_INT:
            return (V.INT, self.take_int())
        if kind == T_STR:
            return (V.STR, self.take_string())
        if kind == T_PUNCT and text == "[":
            self.pos += 1
            items = []
            if not self.at_punct("]"):
                while True:
                    items.append(self.take_value(level + 1))
                    if self.at_punct(","):
                        self.pos += 1
                        continue
                    break
            self.expect_punct("]")
            return (V.LIST, items)
        if kind == T_PUNCT and text == "{":
            self.pos += 1
            fields = []
            seen = set()
            if not self.at_punct("}"):
                while True:
                    name = self.take_field_name()
                    if name in seen:
                        raise TessError("dup-field")
                    seen.add(name)
                    self.expect_punct(":")
                    fields.append((name, self.take_value(level + 1)))
                    if self.at_punct(","):
                        self.pos += 1
                        continue
                    break
            self.expect_punct("}")
            fields.sort(key=lambda f: f[0])
            return (V.OBJ, fields)
        _syntax()

    def take_field_name(self):
        t = self.peek()
        if t is None:
            _syntax()
        if t[0] == T_WORD:
            self.pos += 1
            return t[1].encode("ascii")
        if t[0] == T_STR:
            self.pos += 1
            return resolve_string(t[1])
        _syntax()

    # ---- predicates (§17.1) ----------------------------------------------

    def take_pred(self):
        node = self.take_conj()
        while self.at_word("or"):
            self.pos += 1
            node = ("or", node, self.take_conj())
        return node

    def take_conj(self):
        node = self.take_term()
        while self.at_word("and"):
            self.pos += 1
            node = ("and", node, self.take_term())
        return node

    def take_term(self):
        t = self.peek()
        if t is None:
            _syntax()
        if t[0] == T_PUNCT and t[1] == "(":
            self.pos += 1
            node = self.take_pred()
            self.expect_punct(")")
            return node
        if t[0] != T_WORD:
            _syntax()
        if t[1] == "not" and self.at_punct_at(1, "("):
            self.pos += 2
            node = self.take_pred()
            self.expect_punct(")")
            return ("not", node)
        if t[1] == "exists" and self.is_word_at(1):
            self.pos += 1
            segs, _text = self.take_path()
            return ("exists", segs)
        if t[1] == "missing" and self.is_word_at(1):
            self.pos += 1
            segs, _text = self.take_path()
            return ("missing", segs)
        order = self.pos
        segs, _text = self.take_path()
        op = self.peek()
        if op is None or op[0] != T_OP:
            _syntax()
        self.pos += 1
        value = self.take_value(1)
        return ("cmp", segs, op[1], value, order)

    def at_punct_at(self, ahead, ch):
        t = self.peek(ahead)
        return t is not None and t[0] == T_PUNCT and t[1] == ch

    def is_word_at(self, ahead):
        t = self.peek(ahead)
        return t is not None and t[0] == T_WORD


def parse(line):
    """Lex and parse one line into a Command, or raise a TessError (§18.2)."""
    toks = lex(line)
    if not toks:
        _syntax()
    first = toks[0]
    if first[0] != T_WORD:
        _syntax()
    name = first[1]
    if name not in COMMANDS:
        raise TessError("unknown-command")
    p = Parser(toks)
    p.pos = 1
    cmd = Command(name)

    if name in ("begin", "commit", "rollback", "checkpoint", "stat", "indexes"):
        pass
    elif name == "put":
        cmd.key = p.take_key()
        cmd.value = p.take_value(1)
    elif name in ("get", "delete"):
        cmd.key = p.take_key()
    elif name == "update":
        cmd.key = p.take_key()
        cmd.segs, cmd.path = p.take_path()
        cmd.value = p.take_value(1)
    elif name == "unset":
        cmd.key = p.take_key()
        cmd.segs, cmd.path = p.take_path()
    elif name == "scan":
        seen = set()
        while not p.at_end():
            t = p.peek()
            if t[0] != T_WORD or t[1] not in ("from", "to", "limit", "reverse", "keys"):
                _syntax()
            opt = t[1]
            if opt in seen:
                _syntax()
            seen.add(opt)
            p.pos += 1
            if opt == "from":
                cmd.frm = p.take_string()
            elif opt == "to":
                cmd.to = p.take_string()
            elif opt == "limit":
                cmd.limit = p.take_limit()
            elif opt == "reverse":
                cmd.reverse = True
            else:
                cmd.keys = True
    elif name == "find":
        cmd.pred = p.take_pred()
        if not p.at_end():
            if not p.at_word("limit"):
                _syntax()
            p.pos += 1
            cmd.limit = p.take_limit()
    elif name == "create":
        if not p.at_word("index"):
            _syntax()
        p.pos += 1
        cmd.segs, cmd.path = p.take_path()
        cmd.name = "create index"
    elif name == "drop":
        if not p.at_word("index"):
            _syntax()
        p.pos += 1
        cmd.segs, cmd.path = p.take_path()
        cmd.name = "drop index"

    if not p.at_end():
        _syntax()
    return cmd
