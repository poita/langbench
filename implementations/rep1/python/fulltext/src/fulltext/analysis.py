"""Text analysis: tokenising, case folding, stop words and stemming.

Documents and queries go through the same pipeline: *tokenise* the text into
tokens, *fold* each token into a token text, then *stem* it into a term.
"""

from __future__ import annotations

import re
from array import array

from .stemmer import stem

__all__ = [
    "STOP_WORDS",
    "WHITESPACE",
    "fold",
    "term_for",
    "token_texts",
    "analyze",
    "token_spans",
]

_TOKEN_CHARS = (
    "0-9A-Za-z"
    "\u00c0-\u00d6\u00d8-\u00f6\u00f8-\u024f"  # Latin-1 letters, Latin Extended-A/B
    "\u0370-\u03ff"  # Greek and Coptic
    "\u0400-\u04ff"  # Cyrillic
)

#: A token: token characters, optionally continued by single apostrophes that
#: sit between token characters.
TOKEN_RE = re.compile(
    "[{c}]+(?:['\u2019][{c}]+)*".format(c=_TOKEN_CHARS)
)

#: The seven code points treated as whitespace in queries and snippets.
WHITESPACE = "\t\n\v\f\r \u00a0"

STOP_WORDS = frozenset(
    """a an and are as at be but by for if in into is it no not of on or such
    that the their then there these they this to was will with""".split()
)

_FOLD_TABLE = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}
_FOLD_TABLE[ord("'")] = None
_FOLD_TABLE[0x2019] = None

_ASCII_LOWER = re.compile("[a-z]+")

_term_cache: dict[str, str] = {}


def fold(token: str) -> str:
    """Return the token text: apostrophes deleted, ``A``-``Z`` lower-cased.

    >>> fold("Don’t")
    'dont'
    """
    return token.translate(_FOLD_TABLE)


def term_for(text: str) -> str:
    """Return the index term for a folded token text.

    Tokens made only of ``a``-``z`` are Porter-stemmed; anything else is kept
    unchanged.
    """
    term = _term_cache.get(text)
    if term is None:
        term = stem(text) if _ASCII_LOWER.fullmatch(text) else text
        _term_cache[text] = term
    return term


def token_texts(text: str) -> list[str]:
    """Tokenise and fold ``text``, returning the token texts (no stemming)."""
    return [fold(raw) for raw in TOKEN_RE.findall(text)]


def analyze(text: str) -> list[str]:
    """Return the sequence of terms of ``text``, one per token."""
    return [term_for(fold(raw)) for raw in TOKEN_RE.findall(text)]


def token_spans(text: str) -> tuple[array, array]:
    """Return the ``(starts, ends)`` code point offsets of every token.

    Each ``[start, end)`` is the half-open span the token occupies in ``text``.
    """
    starts = array("I")
    ends = array("I")
    for match in TOKEN_RE.finditer(text):
        start, end = match.span()
        starts.append(start)
        ends.append(end)
    return starts, ends
