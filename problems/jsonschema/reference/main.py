#!/usr/bin/env python3
"""JSON Schema draft 2020-12 validator.

Reads one JSON object {"schema": ..., "tests": [...], "remotes": {...}} on
stdin and prints "valid" or "invalid" for each test, one per line.

Numbers are modelled as exact decimals (mantissa x 10^exponent) so that
comparison, equality and multipleOf never depend on binary floating point.
"""
import json
import sys

sys.setrecursionlimit(200000)

INF = float("inf")


# --------------------------------------------------------------------------
# Exact decimal numbers
# --------------------------------------------------------------------------
class Num:
    """A JSON number held exactly as m * 10**e with m, e integers."""

    __slots__ = ("m", "e")

    def __init__(self, m, e):
        if m == 0:
            e = 0
        else:
            while m % 10 == 0:
                m //= 10
                e += 1
        self.m = m
        self.e = e

    @property
    def is_integer(self):
        return self.e >= 0

    def key(self):
        return (self.m, self.e)

    def __repr__(self):
        return "Num(%d,%d)" % (self.m, self.e)


def parse_num(text):
    """Build a Num from a JSON number literal."""
    neg = False
    i = 0
    if text[0] == "-":
        neg = True
        i = 1
    start = i
    while i < len(text) and text[i].isdigit():
        i += 1
    digits = text[start:i]
    frac = ""
    if i < len(text) and text[i] == ".":
        i += 1
        s2 = i
        while i < len(text) and text[i].isdigit():
            i += 1
        frac = text[s2:i]
    exp = 0
    if i < len(text) and text[i] in "eE":
        i += 1
        sign = 1
        if i < len(text) and text[i] in "+-":
            if text[i] == "-":
                sign = -1
            i += 1
        exp = sign * int(text[i:])
    m = int((digits or "0") + frac)
    if neg:
        m = -m
    return Num(m, exp - len(frac))


def ncmp(a, b):
    """Three-way comparison of two exact decimals."""
    if a.e == b.e:
        am, bm = a.m, b.m
    elif a.e > b.e:
        am, bm = a.m * 10 ** (a.e - b.e), b.m
    else:
        am, bm = a.m, b.m * 10 ** (b.e - a.e)
    return (am > bm) - (am < bm)


def is_multiple(x, d):
    """True when x is an integer multiple of the positive decimal d."""
    if x.m == 0:
        return True
    dm = abs(d.m)
    k = x.e - d.e
    if k >= 0:
        return (x.m * 10 ** k) % dm == 0
    return x.m % (dm * 10 ** (-k)) == 0


# --------------------------------------------------------------------------
# JSON values
# --------------------------------------------------------------------------
def load_json(text):
    return json.loads(text, parse_float=parse_num, parse_int=parse_num)


def type_of(v):
    if v is None:
        return "null"
    if v is True or v is False:
        return "boolean"
    if isinstance(v, Num):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def canon(v):
    """A hashable canonical form; two values are JSON-equal iff these match."""
    if v is None:
        return (0,)
    if v is True or v is False:
        return (1, v)
    if isinstance(v, Num):
        return (2, v.m, v.e)
    if isinstance(v, str):
        return (3, v)
    if isinstance(v, list):
        return (4, tuple(canon(x) for x in v))
    return (5, tuple(sorted((k, canon(x)) for k, x in v.items())))


def jeq(a, b):
    return canon(a) == canon(b)


# --------------------------------------------------------------------------
# Regular expressions (ECMA-262 subset, membership only)
# --------------------------------------------------------------------------
MAXCP = 0x10FFFF
DIGIT = [(0x30, 0x39)]
WORD = [(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)]
SPACE = [(0x09, 0x0D), (0x20, 0x20), (0xA0, 0xA0), (0x1680, 0x1680),
         (0x2000, 0x200A), (0x2028, 0x2029), (0x202F, 0x202F),
         (0x205F, 0x205F), (0x3000, 0x3000), (0xFEFF, 0xFEFF)]
LINE_TERM = [(0x0A, 0x0A), (0x0D, 0x0D), (0x2028, 0x2029)]
CLASS_ESCAPES = {"d": (DIGIT, False), "D": (DIGIT, True),
                 "w": (WORD, False), "W": (WORD, True),
                 "s": (SPACE, False), "S": (SPACE, True)}
CTRL_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "f": "\f", "v": "\v", "0": "\0"}


def complement(ranges):
    out = []
    prev = 0
    for lo, hi in sorted(ranges):
        if lo > prev:
            out.append((prev, lo - 1))
        prev = max(prev, hi + 1)
    if prev <= MAXCP:
        out.append((prev, MAXCP))
    return out


def in_ranges(cp, ranges):
    for lo, hi in ranges:
        if lo <= cp <= hi:
            return True
    return False


class ReParser:
    def __init__(self, src):
        self.s = src
        self.i = 0

    def error(self, msg):
        raise ValueError("bad pattern %r: %s" % (self.s, msg))

    def peek(self):
        return self.s[self.i] if self.i < len(self.s) else ""

    def parse(self):
        node = self.alt()
        if self.i != len(self.s):
            self.error("trailing input at %d" % self.i)
        return node

    def alt(self):
        branches = [self.seq()]
        while self.peek() == "|":
            self.i += 1
            branches.append(self.seq())
        return branches[0] if len(branches) == 1 else ("alt", branches)

    def seq(self):
        parts = []
        while self.i < len(self.s) and self.s[self.i] not in "|)":
            parts.append(self.term())
        if len(parts) == 1:
            return parts[0]
        return ("cat", parts)

    def term(self):
        atom = self.atom()
        c = self.peek()
        lo = hi = None
        if c == "*":
            self.i += 1
            lo, hi = 0, INF
        elif c == "+":
            self.i += 1
            lo, hi = 1, INF
        elif c == "?":
            self.i += 1
            lo, hi = 0, 1
        elif c == "{":
            save = self.i
            self.i += 1
            n = self.digits()
            if n is None:
                self.i = save
            elif self.peek() == "}":
                self.i += 1
                lo, hi = n, n
            elif self.peek() == ",":
                self.i += 1
                if self.peek() == "}":
                    self.i += 1
                    lo, hi = n, INF
                else:
                    m = self.digits()
                    if m is None or self.peek() != "}":
                        self.error("bad quantifier")
                    self.i += 1
                    lo, hi = n, m
            else:
                self.i = save
        if lo is None:
            return atom
        greedy = True
        if self.peek() == "?":
            self.i += 1
            greedy = False
        if atom[0] in ("bol", "eol", "wordb"):
            self.error("quantified anchor")
        return ("rep", atom, lo, hi, greedy)

    def digits(self):
        start = self.i
        while self.i < len(self.s) and self.s[self.i].isdigit():
            self.i += 1
        return int(self.s[start:self.i]) if self.i > start else None

    def atom(self):
        c = self.peek()
        if c == "(":
            self.i += 1
            if self.s.startswith("?:", self.i):
                self.i += 2
            elif self.peek() == "?":
                self.error("unsupported group")
            node = self.alt()
            if self.peek() != ")":
                self.error("missing )")
            self.i += 1
            return node
        if c == "[":
            return self.charclass()
        if c == ".":
            self.i += 1
            return ("class", complement(LINE_TERM))
        if c == "^":
            self.i += 1
            return ("bol",)
        if c == "$":
            self.i += 1
            return ("eol",)
        if c == "\\":
            return self.escape()
        if c in "*+?)":
            self.error("unexpected %r" % c)
        self.i += 1
        return ("char", c)

    def escape(self):
        self.i += 1
        c = self.peek()
        if c == "":
            self.error("trailing backslash")
        self.i += 1
        if c in CLASS_ESCAPES:
            ranges, neg = CLASS_ESCAPES[c]
            return ("class", complement(ranges) if neg else list(ranges))
        if c == "b":
            return ("wordb", False)
        if c == "B":
            return ("wordb", True)
        return ("char", self.escape_char(c))

    def escape_char(self, c):
        """The single character produced by a non-class escape."""
        if c in CTRL_ESCAPES:
            return CTRL_ESCAPES[c]
        if c == "x":
            h = self.s[self.i:self.i + 2]
            if len(h) != 2:
                self.error("bad \\x")
            self.i += 2
            return chr(int(h, 16))
        if c == "u":
            if self.peek() == "{":
                j = self.s.index("}", self.i)
                cp = int(self.s[self.i + 1:j], 16)
                self.i = j + 1
                return chr(cp)
            h = self.s[self.i:self.i + 4]
            if len(h) != 4:
                self.error("bad \\u")
            self.i += 4
            cp = int(h, 16)
            if 0xD800 <= cp <= 0xDBFF and self.s.startswith("\\u", self.i):
                lo = int(self.s[self.i + 2:self.i + 6], 16)
                if 0xDC00 <= lo <= 0xDFFF:
                    self.i += 6
                    return chr(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00))
            return chr(cp)
        if c == "c":
            l = self.peek()
            if l.isalpha():
                self.i += 1
                return chr(ord(l.upper()) - 64)
            return "\\"
        if c.isalnum():
            self.error("unsupported escape \\%s" % c)
        return c

    def charclass(self):
        self.i += 1
        neg = False
        if self.peek() == "^":
            neg = True
            self.i += 1
        ranges = []
        first = True
        while True:
            c = self.peek()
            if c == "":
                self.error("unterminated class")
            if c == "]" and not first:
                self.i += 1
                break
            if c == "]" and first:
                self.error("empty class")
            first = False
            item = self.class_atom()
            if item[0] == "set":
                ranges.extend(item[1])
                continue
            lo = item[1]
            if self.peek() == "-" and self.i + 1 < len(self.s) and self.s[self.i + 1] != "]":
                self.i += 1
                hi_item = self.class_atom()
                if hi_item[0] == "set":
                    self.error("range endpoint is a class escape")
                ranges.append((ord(lo), ord(hi_item[1])))
            else:
                ranges.append((ord(lo), ord(lo)))
        return ("class", complement(ranges) if neg else ranges)

    def class_atom(self):
        c = self.peek()
        if c == "\\":
            self.i += 1
            e = self.peek()
            self.i += 1
            if e in CLASS_ESCAPES:
                ranges, negate = CLASS_ESCAPES[e]
                return ("set", complement(ranges) if negate else list(ranges))
            if e == "b":
                return ("char", "\b")
            return ("char", self.escape_char(e))
        self.i += 1
        return ("char", c)


SIMPLE = ("class", "char")


def re_match(node, s, i, k):
    """Try to match node at i; call k with each end position, greedy-first."""
    t = node[0]
    if t == "char":
        return i < len(s) and s[i] == node[1] and k(i + 1)
    if t == "class":
        return i < len(s) and in_ranges(ord(s[i]), node[1]) and k(i + 1)
    if t == "bol":
        return i == 0 and k(i)
    if t == "eol":
        return i == len(s) and k(i)
    if t == "wordb":
        a = i > 0 and in_ranges(ord(s[i - 1]), WORD)
        b = i < len(s) and in_ranges(ord(s[i]), WORD)
        return ((a != b) != node[1]) and k(i)
    if t == "cat":
        parts = node[1]

        def step(idx, pos):
            if idx == len(parts):
                return k(pos)
            return re_match(parts[idx], s, pos, lambda p: step(idx + 1, p))

        return step(0, i)
    if t == "alt":
        for b in node[1]:
            if re_match(b, s, i, k):
                return True
        return False
    if t == "rep":
        _, sub, lo, hi, greedy = node
        if sub[0] in SIMPLE and greedy:
            return rep_simple(sub, s, i, lo, hi, k)

        def rep(pos, count):
            if count < lo:
                return re_match(sub, s, pos, lambda p: rep(p, count + 1))
            if count == hi:
                return k(pos)
            if greedy:
                if re_match(sub, s, pos, lambda p: False if p == pos else rep(p, count + 1)):
                    return True
                return k(pos)
            if k(pos):
                return True
            return re_match(sub, s, pos, lambda p: False if p == pos else rep(p, count + 1))

        return rep(i, 0)
    raise AssertionError(t)


def rep_simple(sub, s, i, lo, hi, k):
    """Greedy repetition of a single-character atom, matched iteratively."""
    if sub[0] == "char":
        ch = sub[1]
        ok = lambda p: p < len(s) and s[p] == ch
    else:
        rng = sub[1]
        ok = lambda p: p < len(s) and in_ranges(ord(s[p]), rng)
    n = 0
    j = i
    while (hi is INF or n < hi) and ok(j):
        j += 1
        n += 1
    while n >= lo:
        if k(i + n):
            return True
        n -= 1
    return False


class Regex:
    _cache = {}

    def __init__(self, pattern):
        self.node = ReParser(pattern).parse()

    @classmethod
    def get(cls, pattern):
        r = cls._cache.get(pattern)
        if r is None:
            r = cls._cache[pattern] = cls(pattern)
        return r

    def search(self, s):
        node = self.node
        for start in range(len(s) + 1):
            if re_match(node, s, start, lambda p: True):
                return True
        return False


# --------------------------------------------------------------------------
# URI references (RFC 3986)
# --------------------------------------------------------------------------
SCHEME_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")


def uri_split(u):
    """Split a URI reference into (scheme, authority, path, query, fragment).

    Absent components are None; an empty-but-present component is "".
    """
    frag = None
    h = u.find("#")
    if h >= 0:
        frag = u[h + 1:]
        u = u[:h]
    query = None
    q = u.find("?")
    if q >= 0:
        query = u[q + 1:]
        u = u[:q]
    scheme = None
    c = u.find(":")
    if c > 0 and u[0].isalpha() and all(ch in SCHEME_CHARS for ch in u[:c]):
        if not any(ch in u[:c] for ch in "/?#"):
            scheme = u[:c]
            u = u[c + 1:]
    authority = None
    if u.startswith("//"):
        rest = u[2:]
        cut = len(rest)
        for ch in "/":
            p = rest.find(ch)
            if p >= 0:
                cut = min(cut, p)
        authority = rest[:cut]
        u = rest[cut:]
    return scheme, authority, u, query, frag


def remove_dot_segments(path):
    out = []
    while path:
        if path.startswith("../"):
            path = path[3:]
        elif path.startswith("./"):
            path = path[2:]
        elif path.startswith("/./"):
            path = "/" + path[3:]
        elif path == "/.":
            path = "/"
        elif path.startswith("/../"):
            path = "/" + path[4:]
            if out:
                out.pop()
        elif path == "/..":
            path = "/"
            if out:
                out.pop()
        elif path in (".", ".."):
            path = ""
        else:
            i = path.find("/", 1)
            if i < 0:
                i = len(path)
            out.append(path[:i])
            path = path[i:]
    return "".join(out)


def uri_merge(base_auth, base_path, ref_path):
    if base_auth is not None and base_path == "":
        return "/" + ref_path
    i = base_path.rfind("/")
    return base_path[:i + 1] + ref_path if i >= 0 else ref_path


def uri_recompose(scheme, authority, path, query, fragment):
    out = ""
    if scheme is not None:
        out += scheme + ":"
    if authority is not None:
        out += "//" + authority
    out += path
    if query is not None:
        out += "?" + query
    if fragment is not None:
        out += "#" + fragment
    return out


def uri_resolve(base, ref):
    """RFC 3986 section 5.2.2 strict reference resolution."""
    bs, ba, bp, bq, _ = uri_split(base)
    rs, ra, rp, rq, rf = uri_split(ref)
    if rs is not None:
        return uri_recompose(rs, ra, remove_dot_segments(rp), rq, rf)
    if ra is not None:
        return uri_recompose(bs, ra, remove_dot_segments(rp), rq, rf)
    if rp == "":
        return uri_recompose(bs, ba, bp, bq if rq is None else rq, rf)
    if rp.startswith("/"):
        return uri_recompose(bs, ba, remove_dot_segments(rp), rq, rf)
    return uri_recompose(bs, ba, remove_dot_segments(uri_merge(ba, bp, rp)), rq, rf)


HEX = "0123456789abcdefABCDEF"


def pct_decode(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "%" and i + 2 < len(s) + 1 and len(s) - i >= 3 and s[i + 1] in HEX and s[i + 2] in HEX:
            out.append(int(s[i + 1:i + 3], 16))
            i += 3
        else:
            out.append(None)
            out[-1] = s[i]
            i += 1
    # Re-assemble, decoding runs of bytes as UTF-8.
    res = []
    buf = bytearray()
    for item in out:
        if isinstance(item, int):
            buf.append(item)
        else:
            if buf:
                res.append(buf.decode("utf-8", "replace"))
                buf = bytearray()
            res.append(item)
    if buf:
        res.append(buf.decode("utf-8", "replace"))
    return "".join(res)


def split_fragment(uri):
    h = uri.find("#")
    if h < 0:
        return uri, ""
    return uri[:h], uri[h + 1:]


def json_pointer(doc, pointer):
    node = doc
    for raw in pointer.split("/")[1:]:
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, list):
            node = node[int(token)]
        elif isinstance(node, dict):
            node = node[token]
        else:
            raise KeyError(pointer)
    return node


# --------------------------------------------------------------------------
# Schema indexing
# --------------------------------------------------------------------------
SCHEMA_KEYS = ("additionalProperties", "propertyNames", "items", "contains",
               "not", "if", "then", "else", "unevaluatedItems",
               "unevaluatedProperties", "contentSchema")
SCHEMA_LIST_KEYS = ("allOf", "anyOf", "oneOf", "prefixItems")
SCHEMA_MAP_KEYS = ("$defs", "properties", "patternProperties", "dependentSchemas")


class Registry:
    def __init__(self):
        self.resources = {}       # absolute URI without fragment -> root node
        self.anchors = {}         # (base, name) -> node
        self.dynamic = set()      # (base, name)
        self.node_base = {}       # id(node) -> base URI of its resource
        self.resource_root = set()  # id(node) for schema resource roots
        self.keep = []            # keeps indexed documents alive

    def add_document(self, doc, retrieval_uri):
        self.keep.append(doc)
        self.resources.setdefault(retrieval_uri, doc)
        self.walk(doc, retrieval_uri, root=True)

    def walk(self, node, base, root=False):
        if not isinstance(node, dict):
            return
        if isinstance(node.get("$id"), str):
            base = uri_resolve(base, split_fragment(node["$id"])[0])
            self.resources[base] = node
            self.resource_root.add(id(node))
        elif root:
            self.resources.setdefault(base, node)
            self.resource_root.add(id(node))
        self.node_base[id(node)] = base
        anchor = node.get("$anchor")
        if isinstance(anchor, str):
            self.anchors[(base, anchor)] = node
        danchor = node.get("$dynamicAnchor")
        if isinstance(danchor, str):
            self.anchors.setdefault((base, danchor), node)
            self.dynamic.add((base, danchor))
        for key in SCHEMA_KEYS:
            if key in node:
                self.walk(node[key], base)
        for key in SCHEMA_LIST_KEYS:
            v = node.get(key)
            if isinstance(v, list):
                for sub in v:
                    self.walk(sub, base)
        for key in SCHEMA_MAP_KEYS:
            v = node.get(key)
            if isinstance(v, dict):
                for sub in v.values():
                    self.walk(sub, base)

    def base_of(self, node):
        return self.node_base.get(id(node), "")

    def lookup(self, uri):
        """Resolve an absolute URI (with optional fragment) to a schema node."""
        doc_uri, frag = split_fragment(uri)
        frag = pct_decode(frag)
        if frag == "":
            node = self.resources.get(doc_uri)
            if node is None:
                raise KeyError(uri)
            return node
        if frag.startswith("/"):
            root = self.resources.get(doc_uri)
            if root is None:
                raise KeyError(uri)
            return json_pointer(root, frag)
        node = self.anchors.get((doc_uri, frag))
        if node is None:
            raise KeyError(uri)
        return node


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
class Result:
    __slots__ = ("ok", "props", "items")

    def __init__(self, ok, props=None, items=None):
        self.ok = ok
        self.props = props if props is not None else set()
        self.items = items if items is not None else set()


IGNORED = {"$schema", "$vocabulary", "$comment", "$id", "$anchor",
           "$dynamicAnchor", "$defs", "title", "description", "default",
           "deprecated", "readOnly", "writeOnly", "examples", "format",
           "contentEncoding", "contentMediaType", "contentSchema",
           "definitions", "dependencies"}


class Validator:
    def __init__(self, registry):
        self.reg = registry

    def validate(self, node, inst, scope):
        if node is True:
            return Result(True)
        if node is False:
            return Result(False)
        if not isinstance(node, dict):
            return Result(True)
        base = self.reg.base_of(node)
        if not scope or scope[-1] != base:
            scope = scope + (base,)
        props = set()
        items = set()
        ok = True

        for key, value in node.items():
            if key in IGNORED or key in ("unevaluatedItems", "unevaluatedProperties"):
                continue
            r = self.apply_keyword(key, value, node, inst, scope, base)
            if r is None:
                continue
            if not r.ok:
                ok = False
            else:
                props |= r.props
                items |= r.items

        if not ok:
            return Result(False)

        if "unevaluatedItems" in node and isinstance(inst, list):
            sub = node["unevaluatedItems"]
            for idx in range(len(inst)):
                if idx in items:
                    continue
                if not self.validate(sub, inst[idx], scope).ok:
                    return Result(False)
                items.add(idx)
        if "unevaluatedProperties" in node and type_of(inst) == "object":
            sub = node["unevaluatedProperties"]
            for name, val in inst.items():
                if name in props:
                    continue
                if not self.validate(sub, val, scope).ok:
                    return Result(False)
                props.add(name)
        return Result(True, props, items)

    def apply_keyword(self, key, value, node, inst, scope, base):
        t = type_of(inst)

        if key == "$ref":
            target = self.reg.lookup(uri_resolve(base, value))
            return self.validate(target, inst, scope)
        if key == "$dynamicRef":
            target = self.resolve_dynamic(value, base, scope)
            return self.validate(target, inst, scope)

        if key == "type":
            names = value if isinstance(value, list) else [value]
            for name in names:
                if name == t or (name == "integer" and t == "number" and inst.is_integer):
                    return Result(True)
            return Result(False)
        if key == "enum":
            target = canon(inst)
            return Result(any(canon(v) == target for v in value))
        if key == "const":
            return Result(jeq(inst, value))

        if key in ("multipleOf", "maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum"):
            if t != "number":
                return None
            if key == "multipleOf":
                return Result(is_multiple(inst, value))
            c = ncmp(inst, value)
            if key == "maximum":
                return Result(c <= 0)
            if key == "minimum":
                return Result(c >= 0)
            if key == "exclusiveMaximum":
                return Result(c < 0)
            return Result(c > 0)

        if key in ("maxLength", "minLength", "pattern"):
            if t != "string":
                return None
            if key == "maxLength":
                return Result(len(inst) <= value.m * 10 ** value.e)
            if key == "minLength":
                return Result(len(inst) >= value.m * 10 ** value.e)
            return Result(Regex.get(value).search(inst))

        if key in ("maxItems", "minItems", "uniqueItems", "prefixItems", "items",
                   "contains", "maxContains", "minContains"):
            if t != "array":
                return None
            return self.array_keyword(key, value, node, inst, scope)

        if key in ("maxProperties", "minProperties", "required", "dependentRequired",
                   "properties", "patternProperties", "additionalProperties",
                   "propertyNames", "dependentSchemas"):
            if t != "object":
                return None
            return self.object_keyword(key, value, node, inst, scope)

        if key == "allOf":
            props, items = set(), set()
            for sub in value:
                r = self.validate(sub, inst, scope)
                if not r.ok:
                    return Result(False)
                props |= r.props
                items |= r.items
            return Result(True, props, items)
        if key == "anyOf":
            ok = False
            props, items = set(), set()
            for sub in value:
                r = self.validate(sub, inst, scope)
                if r.ok:
                    ok = True
                    props |= r.props
                    items |= r.items
            return Result(ok, props, items) if ok else Result(False)
        if key == "oneOf":
            hits = []
            for sub in value:
                r = self.validate(sub, inst, scope)
                if r.ok:
                    hits.append(r)
            if len(hits) != 1:
                return Result(False)
            return hits[0]
        if key == "not":
            return Result(not self.validate(value, inst, scope).ok)
        if key == "if":
            r = self.validate(value, inst, scope)
            branch = node.get("then") if r.ok else node.get("else")
            props = set(r.props) if r.ok else set()
            items = set(r.items) if r.ok else set()
            if branch is not None:
                br = self.validate(branch, inst, scope)
                if not br.ok:
                    return Result(False)
                props |= br.props
                items |= br.items
            return Result(True, props, items)
        if key in ("then", "else"):
            return None  # handled by "if"
        return None      # unknown keyword: ignored

    def array_keyword(self, key, value, node, inst, scope):
        if key == "maxItems":
            return Result(len(inst) <= value.m * 10 ** value.e)
        if key == "minItems":
            return Result(len(inst) >= value.m * 10 ** value.e)
        if key == "uniqueItems":
            if value is not True:
                return Result(True)
            seen = set()
            for v in inst:
                c = canon(v)
                if c in seen:
                    return Result(False)
                seen.add(c)
            return Result(True)
        if key == "prefixItems":
            items = set()
            for i in range(min(len(value), len(inst))):
                if not self.validate(value[i], inst[i], scope).ok:
                    return Result(False)
                items.add(i)
            return Result(True, items=items)
        if key == "items":
            start = 0
            pre = node.get("prefixItems")
            if isinstance(pre, list):
                start = len(pre)
            items = set()
            for i in range(start, len(inst)):
                if not self.validate(value, inst[i], scope).ok:
                    return Result(False)
                items.add(i)
            return Result(True, items=items)
        if key == "contains":
            hits = set()
            for i, v in enumerate(inst):
                if self.validate(value, v, scope).ok:
                    hits.add(i)
            lo = node.get("minContains")
            hi = node.get("maxContains")
            lo_n = lo.m * 10 ** lo.e if isinstance(lo, Num) else 1
            if len(hits) < lo_n:
                return Result(False)
            if isinstance(hi, Num) and len(hits) > hi.m * 10 ** hi.e:
                return Result(False)
            return Result(True, items=hits)
        return None  # maxContains/minContains are handled by "contains"

    def object_keyword(self, key, value, node, inst, scope):
        if key == "maxProperties":
            return Result(len(inst) <= value.m * 10 ** value.e)
        if key == "minProperties":
            return Result(len(inst) >= value.m * 10 ** value.e)
        if key == "required":
            return Result(all(name in inst for name in value))
        if key == "dependentRequired":
            for name, needed in value.items():
                if name in inst and not all(n in inst for n in needed):
                    return Result(False)
            return Result(True)
        if key == "properties":
            props = set()
            for name, sub in value.items():
                if name in inst:
                    if not self.validate(sub, inst[name], scope).ok:
                        return Result(False)
                    props.add(name)
            return Result(True, props=props)
        if key == "patternProperties":
            props = set()
            for pattern, sub in value.items():
                rx = Regex.get(pattern)
                for name, val in inst.items():
                    if rx.search(name):
                        if not self.validate(sub, val, scope).ok:
                            return Result(False)
                        props.add(name)
            return Result(True, props=props)
        if key == "additionalProperties":
            named = node.get("properties")
            patterns = node.get("patternProperties")
            props = set()
            for name, val in inst.items():
                if isinstance(named, dict) and name in named:
                    continue
                if isinstance(patterns, dict) and any(
                        Regex.get(p).search(name) for p in patterns):
                    continue
                if not self.validate(value, val, scope).ok:
                    return Result(False)
                props.add(name)
            return Result(True, props=props)
        if key == "propertyNames":
            for name in inst:
                if not self.validate(value, name, scope).ok:
                    return Result(False)
            return Result(True)
        if key == "dependentSchemas":
            props, items = set(), set()
            for name, sub in value.items():
                if name in inst:
                    r = self.validate(sub, inst, scope)
                    if not r.ok:
                        return Result(False)
                    props |= r.props
                    items |= r.items
            return Result(True, props, items)
        return None

    def resolve_dynamic(self, value, base, scope):
        target_uri = uri_resolve(base, value)
        doc_uri, frag = split_fragment(target_uri)
        name = pct_decode(frag)
        if name and not name.startswith("/") and (doc_uri, name) in self.reg.dynamic:
            for outer in scope:
                if (outer, name) in self.reg.dynamic:
                    return self.reg.anchors[(outer, name)]
        return self.reg.lookup(target_uri)


# --------------------------------------------------------------------------
def main():
    doc = load_json(sys.stdin.read())
    reg = Registry()
    remotes = doc.get("remotes") or {}
    for uri, remote in remotes.items():
        reg.add_document(remote, uri)
    schema = doc["schema"]
    reg.add_document(schema, "")
    validator = Validator(reg)
    out = []
    for case in doc["tests"]:
        out.append("valid" if validator.validate(schema, case["data"], ()).ok else "invalid")
    sys.stdout.write("".join(line + "\n" for line in out))


if __name__ == "__main__":
    main()
