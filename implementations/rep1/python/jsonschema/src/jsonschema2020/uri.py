"""URI handling: RFC 3986 reference resolution and RFC 6901 JSON Pointers.

Only what JSON Schema reference resolution needs is implemented: splitting a
reference into components, resolving it against a base (RFC 3986 section
5.2.2, strict), recomposing, and percent-decoding fragments.
"""

from __future__ import annotations

from typing import Any, NamedTuple, Optional

__all__ = [
    "URIParts",
    "split",
    "unsplit",
    "resolve",
    "remove_dot_segments",
    "split_fragment",
    "percent_decode",
    "parse_pointer",
    "evaluate_pointer",
    "PointerError",
]

_SCHEME_FIRST = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
_SCHEME_REST = _SCHEME_FIRST | frozenset("0123456789+-.")


class URIParts(NamedTuple):
    """The five components of RFC 3986 section 3; ``None`` means "undefined"."""

    scheme: Optional[str]
    authority: Optional[str]
    path: str
    query: Optional[str]
    fragment: Optional[str]


def split(uri: str) -> URIParts:
    """Split a URI reference into its components (RFC 3986 appendix B)."""
    fragment = None
    hash_at = uri.find("#")
    if hash_at >= 0:
        fragment = uri[hash_at + 1 :]
        uri = uri[:hash_at]
    query = None
    q_at = uri.find("?")
    if q_at >= 0:
        query = uri[q_at + 1 :]
        uri = uri[:q_at]
    scheme = None
    i = 0
    n = len(uri)
    if n and uri[0] in _SCHEME_FIRST:
        i = 1
        while i < n and uri[i] in _SCHEME_REST:
            i += 1
        if i < n and uri[i] == ":":
            scheme = uri[:i]
            uri = uri[i + 1 :]
    authority = None
    if uri.startswith("//"):
        slash = uri.find("/", 2)
        if slash < 0:
            authority, uri = uri[2:], ""
        else:
            authority, uri = uri[2:slash], uri[slash:]
    return URIParts(scheme, authority, uri, query, fragment)


def unsplit(parts: URIParts) -> str:
    """Recompose components into a string (RFC 3986 section 5.3)."""
    out = []
    if parts.scheme is not None:
        out.append(parts.scheme + ":")
    if parts.authority is not None:
        out.append("//" + parts.authority)
    out.append(parts.path)
    if parts.query is not None:
        out.append("?" + parts.query)
    if parts.fragment is not None:
        out.append("#" + parts.fragment)
    return "".join(out)


def remove_dot_segments(path: str) -> str:
    """RFC 3986 section 5.2.4."""
    out: list = []
    inp = path
    while inp:
        if inp.startswith("../"):
            inp = inp[3:]
        elif inp.startswith("./"):
            inp = inp[2:]
        elif inp.startswith("/./"):
            inp = inp[2:]
        elif inp == "/.":
            inp = "/"
        elif inp.startswith("/../"):
            inp = inp[3:]
            if out:
                out.pop()
        elif inp == "/..":
            inp = "/"
            if out:
                out.pop()
        elif inp == "." or inp == "..":
            inp = ""
        else:
            start = 1 if inp[0] == "/" else 0
            nxt = inp.find("/", start)
            if nxt < 0:
                nxt = len(inp)
            out.append(inp[:nxt])
            inp = inp[nxt:]
    return "".join(out)


def _merge(base: URIParts, ref_path: str) -> str:
    if base.authority is not None and base.path == "":
        return "/" + ref_path
    slash = base.path.rfind("/")
    return base.path[: slash + 1] + ref_path


def resolve(base: str, reference: str) -> str:
    """Resolve *reference* against *base* (RFC 3986 section 5.2.2, strict)."""
    r = split(reference)
    b = split(base)
    if r.scheme is not None:
        scheme, authority = r.scheme, r.authority
        path, query = remove_dot_segments(r.path), r.query
    else:
        if r.authority is not None:
            authority = r.authority
            path, query = remove_dot_segments(r.path), r.query
        else:
            authority = b.authority
            if r.path == "":
                path = b.path
                query = r.query if r.query is not None else b.query
            else:
                if r.path.startswith("/"):
                    path = remove_dot_segments(r.path)
                else:
                    path = remove_dot_segments(_merge(b, r.path))
                query = r.query
        scheme = b.scheme
    return unsplit(URIParts(scheme, authority, path, query, r.fragment))


def split_fragment(uri: str) -> "tuple[str, Optional[str]]":
    """Split ``uri`` into (everything before ``#``, the fragment or ``None``)."""
    hash_at = uri.find("#")
    if hash_at < 0:
        return uri, None
    return uri[:hash_at], uri[hash_at + 1 :]


_HEX = frozenset("0123456789abcdefABCDEF")


def _is_hex_pair(text: str, i: int) -> bool:
    return i + 1 < len(text) and text[i] in _HEX and text[i + 1] in _HEX


def percent_decode(text: str) -> str:
    """Decode ``%XX`` escapes, interpreting the resulting bytes as UTF-8.

    Malformed escapes are left alone; invalid UTF-8 is replaced.
    """
    if "%" not in text:
        return text
    out = bytearray()
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "%" and _is_hex_pair(text, i + 1):
            out.append(int(text[i + 1 : i + 3], 16))
            i += 3
        else:
            out += ch.encode("utf-8", "surrogatepass")
            i += 1
    return out.decode("utf-8", "replace")


class PointerError(LookupError):
    """A JSON Pointer does not lead anywhere in the document."""


def parse_pointer(pointer: str) -> "list[str]":
    """Split an RFC 6901 pointer (``""`` or ``/a/b``) into unescaped tokens."""
    if pointer == "":
        return []
    if not pointer.startswith("/"):
        raise PointerError(f"invalid JSON Pointer {pointer!r}")
    return [t.replace("~1", "/").replace("~0", "~") for t in pointer[1:].split("/")]


def evaluate_pointer(document: Any, pointer: str) -> Any:
    """Return the value *pointer* designates inside *document*."""
    node = document
    for token in parse_pointer(pointer):
        if type(node) is dict:
            if token not in node:
                raise PointerError(f"no member {token!r} while evaluating {pointer!r}")
            node = node[token]
        elif type(node) is list:
            if not token.isascii() or not token.isdigit() or (
                len(token) > 1 and token[0] == "0"
            ):
                raise PointerError(f"bad array index {token!r} in {pointer!r}")
            index = int(token)
            if index >= len(node):
                raise PointerError(f"index {index} out of range in {pointer!r}")
            node = node[index]
        else:
            raise PointerError(f"cannot descend into a scalar in {pointer!r}")
    return node
