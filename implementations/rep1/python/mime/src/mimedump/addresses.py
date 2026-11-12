"""Address-list parsing (a forgiving subset of RFC 5322 mailboxes and groups)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .lexical import read_quoted, skip_comment
from .rfc2047 import decode_display, match_encoded_word

ATOM, QUOTED, LITERAL, ENCODED, SPECIAL = "atom", "quoted", "literal", "encoded", "special"

_SPECIALS = "<>@,:;."
_ATOM_RUN = re.compile(r'[^ \t()<>\[\]@,:;."\\]+')


@dataclass(frozen=True, slots=True)
class Token:
    """A lexical token of an address list; ``start`` is its offset in the value."""

    kind: str
    text: str
    start: int


@dataclass(frozen=True, slots=True)
class Address:
    """A parsed mailbox: a decoded display name (possibly empty) and an address."""

    display: str
    spec: str


def tokenize(v: str) -> list[Token]:
    """Split an address-list value into tokens (comments and blanks vanish)."""
    tokens: list[Token] = []
    n = len(v)
    i = 0
    while i < n:
        c = v[i]
        if c in " \t":
            i += 1
        elif c == "(":
            i = skip_comment(v, i)
        elif c == '"':
            text, end = read_quoted(v, i)
            tokens.append(Token(QUOTED, text, i))
            i = end
        elif c == "[":
            j = i + 1
            end = n
            while j < n:
                if v[j] == "\\":
                    j += 2
                elif v[j] == "]":
                    end = j + 1
                    break
                else:
                    j += 1
            tokens.append(Token(LITERAL, v[i:end], i))
            i = end
        else:
            word = match_encoded_word(v, i) if c == "=" else None
            if word is not None:
                tokens.append(Token(ENCODED, word[0], i))
                i = word[1]
            elif c in _SPECIALS:
                tokens.append(Token(SPECIAL, c, i))
                i += 1
            else:
                m = _ATOM_RUN.match(v, i)
                end = m.end() if m else i + 1
                tokens.append(Token(ATOM, v[i:end], i))
                i = end
    return tokens


def _is_special(tok: Token, char: str) -> bool:
    return tok.kind == SPECIAL and tok.text == char


def _split_elements(tokens: list[Token]) -> list[list[Token]]:
    elements: list[list[Token]] = [[]]
    depth = 0
    for tok in tokens:
        if _is_special(tok, "<"):
            depth += 1
        elif _is_special(tok, ">"):
            depth = max(depth - 1, 0)
        elif _is_special(tok, ",") and depth == 0:
            elements.append([])
            continue
        elements[-1].append(tok)
    return elements


def _dotted(tokens: list[Token], kinds: tuple[str, ...]) -> list[str] | None:
    """Texts of tokens alternating strictly with ``.`` tokens, or ``None``."""
    if not tokens or len(tokens) % 2 == 0:
        return None
    texts: list[str] = []
    for k, tok in enumerate(tokens):
        if k % 2 == 0:
            if tok.kind not in kinds:
                return None
            texts.append(tok.text)
        elif not _is_special(tok, "."):
            return None
    return texts


def _addr_spec(tokens: list[Token]) -> str | None:
    """Render ``local[@domain]`` if *tokens* have that shape, else ``None``."""
    ats = [k for k, t in enumerate(tokens) if _is_special(t, "@")]
    if len(ats) > 1:
        return None
    local = _dotted(tokens[:ats[0]] if ats else tokens, (ATOM, QUOTED))
    if local is None:
        return None
    if not ats:
        return ".".join(local)
    domain_tokens = tokens[ats[0] + 1:]
    if len(domain_tokens) == 1 and domain_tokens[0].kind == LITERAL:
        domain = [domain_tokens[0].text]
    else:
        domain = _dotted(domain_tokens, (ATOM,))
        if domain is None:
            return None
    return ".".join(local) + "@" + ".".join(domain)


def _parse_element(value: str, tokens: list[Token]) -> Address | None:
    for k, tok in enumerate(tokens):
        if tok.kind == SPECIAL and tok.text in "<@:":
            if tok.text == ":":
                tokens = tokens[k + 1:]  # drop the group name
            break
    if tokens and _is_special(tokens[-1], ";"):
        tokens = tokens[:-1]
    if not tokens:
        return None
    lt = next((k for k, t in enumerate(tokens) if _is_special(t, "<")), None)
    if lt is not None:
        gt = next(
            (k for k in range(len(tokens) - 1, lt, -1) if _is_special(tokens[k], ">")),
            None,
        )
        if gt is not None:
            spec = _addr_spec(tokens[lt + 1:gt])
            if spec is not None:
                phrase = value[tokens[0].start:tokens[lt].start]
                return Address(decode_display(phrase), spec)
    spec = _addr_spec(tokens)
    if spec is not None:
        return Address("", spec)
    return Address("", "".join(t.text for t in tokens))


def parse_address_list(value: str) -> list[Address]:
    """Parse a ``From``/``To``-style header value into addresses."""
    addresses = []
    for element in _split_elements(tokenize(value)):
        address = _parse_element(value, element)
        if address is not None:
            addresses.append(address)
    return addresses
