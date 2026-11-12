"""The Porter stemmer (Martin Porter's 1980 algorithm, as in ``porter.c``).

Includes the two departures from the published paper made by the reference
implementation (``BLI -> BLE`` and the extra ``LOGI -> LOG`` rule).

Only :func:`stem` is public; it expects a non-empty string of ``a``-``z``.
"""

from __future__ import annotations

__all__ = ["stem"]

_VOWELS = frozenset("aeiou")


def _consonants(s: str) -> list[bool]:
    """Per-letter consonant flags; ``y`` is a consonant unless after a consonant."""
    flags: list[bool] = []
    for i, ch in enumerate(s):
        if ch in _VOWELS:
            flags.append(False)
        elif ch == "y":
            flags.append(i == 0 or not flags[i - 1])
        else:
            flags.append(True)
    return flags


def _measure(s: str) -> int:
    """The number of VC sequences in ``s`` (Porter's ``m``)."""
    flags = _consonants(s)
    m = 0
    prev_vowel = False
    for is_cons in flags:
        if is_cons:
            if prev_vowel:
                m += 1
            prev_vowel = False
        else:
            prev_vowel = True
    return m


def _has_vowel(s: str) -> bool:
    return not all(_consonants(s))


def _ends_double_consonant(s: str) -> bool:
    return len(s) >= 2 and s[-1] == s[-2] and _consonants(s)[-1]


def _ends_cvc(s: str) -> bool:
    """``*o``: ends consonant-vowel-consonant, last not ``w``, ``x`` or ``y``."""
    if len(s) < 3 or s[-1] in "wxy":
        return False
    flags = _consonants(s)
    return flags[-1] and not flags[-2] and flags[-3]


def _step1a(w: str) -> str:
    if w.endswith("sses"):
        return w[:-2]
    if w.endswith("ies"):
        return w[:-2]
    if w.endswith("ss"):
        return w
    if w.endswith("s"):
        return w[:-1]
    return w


def _step1b(w: str) -> str:
    if w.endswith("eed"):
        return w[:-1] if _measure(w[:-3]) > 0 else w
    for suffix in ("ed", "ing"):
        if w.endswith(suffix):
            stem_ = w[: -len(suffix)]
            if not _has_vowel(stem_):
                return w
            w = stem_
            break
    else:
        return w
    if w.endswith("at") or w.endswith("bl") or w.endswith("iz"):
        return w + "e"
    if _ends_double_consonant(w):
        return w[:-1] if w[-1] not in "lsz" else w
    if _measure(w) == 1 and _ends_cvc(w):
        return w + "e"
    return w


def _step1c(w: str) -> str:
    if w.endswith("y") and _has_vowel(w[:-1]):
        return w[:-1] + "i"
    return w


_STEP2 = (
    ("ational", "ate"), ("tional", "tion"), ("enci", "ence"), ("anci", "ance"),
    ("izer", "ize"), ("bli", "ble"), ("alli", "al"), ("entli", "ent"),
    ("eli", "e"), ("ousli", "ous"), ("ization", "ize"), ("ation", "ate"),
    ("ator", "ate"), ("alism", "al"), ("iveness", "ive"), ("fulness", "ful"),
    ("ousness", "ous"), ("aliti", "al"), ("iviti", "ive"), ("biliti", "ble"),
    ("logi", "log"),
)

_STEP3 = (
    ("icate", "ic"), ("ative", ""), ("alize", "al"), ("iciti", "ic"),
    ("ical", "ic"), ("ful", ""), ("ness", ""),
)

_STEP4 = (
    "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
    "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
)


def _replace_first(w: str, rules: tuple[tuple[str, str], ...]) -> str:
    """Apply the first rule whose suffix matches, if its stem has ``m > 0``."""
    for suffix, replacement in rules:
        if w.endswith(suffix):
            stem_ = w[: -len(suffix)]
            if _measure(stem_) > 0:
                return stem_ + replacement
            return w
    return w


def _step4(w: str) -> str:
    for suffix in _STEP4:
        if w.endswith(suffix):
            stem_ = w[: -len(suffix)]
            if suffix == "ion" and not stem_.endswith(("s", "t")):
                return w
            return stem_ if _measure(stem_) > 1 else w
    return w


def _step5(w: str) -> str:
    if w.endswith("e"):
        stem_ = w[:-1]
        m = _measure(stem_)
        if m > 1 or (m == 1 and not _ends_cvc(stem_)):
            w = stem_
    if w.endswith("l") and _ends_double_consonant(w) and _measure(w) > 1:
        w = w[:-1]
    return w


def stem(word: str) -> str:
    """Return the Porter stem of ``word`` (lower-case ASCII letters).

    Words of one or two letters are returned unchanged.

    >>> stem("relational")
    'relat'
    >>> stem("feed")
    'feed'
    """
    if len(word) <= 2:
        return word
    w = _step1a(word)
    w = _step1b(w)
    w = _step1c(w)
    w = _replace_first(w, _STEP2)
    w = _replace_first(w, _STEP3)
    w = _step4(w)
    return _step5(w)
