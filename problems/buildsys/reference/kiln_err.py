"""The single error type every Kiln failure is reported through."""


class KilnError(Exception):
    """A build error: one kind and an optional detail, both byte strings."""

    def __init__(self, kind, detail=None):
        Exception.__init__(self, kind)
        self.kind = kind
        self.detail = detail

    def render(self):
        if self.detail is None:
            return self.kind
        return self.kind + b" " + self.detail


def parse_error(filename, line):
    return KilnError(b"E_PARSE", filename + b":" + b"%d" % line)


def vtype(v):
    """The type token of a KBL value. ``bool`` is checked before ``int``
    because Python's ``bool`` is a subclass of ``int``."""
    if v is True or v is False:
        return b"bool"
    if isinstance(v, int):
        return b"int"
    if isinstance(v, bytes):
        return b"str"
    if isinstance(v, list):
        return b"list"
    raise AssertionError("not a KBL value: %r" % (v,))


_TYPE_SETS = {
    b"str": (b"str",),
    b"int": (b"int",),
    b"bool": (b"bool",),
    b"list": (b"list",),
    b"str|list": (b"str", b"list"),
    b"str|int": (b"str", b"int"),
    b"str|int|bool": (b"str", b"int", b"bool"),
}


def need_type(v, expected, site):
    """Raise ``E_TYPE`` unless ``v``'s type is one of ``expected``'s types."""
    t = vtype(v)
    if t not in _TYPE_SETS[expected]:
        raise KilnError(
            b"E_TYPE", site + b": expected " + expected + b", got " + t)
    return v


def as_strlist(v, site):
    """Coerce a ``strlist`` site's value to a list of byte strings."""
    t = vtype(v)
    if t == b"str":
        return [v]
    if t == b"list":
        for e in v:
            et = vtype(e)
            if et != b"str":
                raise KilnError(
                    b"E_TYPE", site + b": expected strlist, got " + et)
        return list(v)
    raise KilnError(b"E_TYPE", site + b": expected strlist, got " + t)
