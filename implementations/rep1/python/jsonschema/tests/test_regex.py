import time

import pytest

from jsonschema2020.regex import RegexError, compile_pattern, search

MATCH = [
    ("bar", "foobarbaz"),
    ("^a", "abc"),
    ("c$", "abc"),
    ("^abc$", "abc"),
    ("a|b", "xxb"),
    ("^(a|ab)(c|bcd)(d*)$", "abcd"),
    ("(?:ab)+", "xababx"),
    ("a{2}", "baab"),
    ("a{2,}", "aaaa"),
    ("^a{2,3}$", "aaa"),
    ("a{,2}", "a{,2}"),
    ("x{", "x{"),
    ("a*?b", "aab"),
    ("^.$", "é"),
    ("^.$", "\U0001F4A9"),
    ("^[a-c]+$", "abcabc"),
    ("^[^a-c]+$", "xyz"),
    ("^[\\w-]+$", "ab-c_9"),
    ("^[a\\-z]+$", "a-z"),
    ("^[-a]+$", "-a"),
    ("^[a-]+$", "-a"),
    (r"^\d+$", "0123"),
    (r"^\D+$", "abc"),
    (r"^\s+$", "\t\n  ﻿"),
    (r"^\S+$", "abc"),
    (r"^\W+$", "- !"),
    (r"\bcat\b", "écat "),
    (r"\Bcat", "concat"),
    (r"^\x41B\n\t$", "AB\n\t"),
    (r"^💩$", "\U0001F4A9"),
    (r"^\cJ$", "\n"),
    (r"^\0$", "\0"),
    (r"^[\b]$", "\b"),
    (r"^\.\*\[\/\-$", ".*[/-"),
    ("", ""),
    ("(?:)", "abc"),
    ("x*", ""),
    ("^(a+)+$", "aaaa"),
    ("]", "]"),
    ("}", "}"),
]

NO_MATCH = [
    ("^abc$", "abcd"),
    ("^a$", "a\n"),
    ("a.c", "a\nc"),
    ("^.$", "\n"),
    ("a{2}", "a"),
    ("^a{2,3}$", "aaaa"),
    ("^[a-c]+$", "abd"),
    (r"^\d+$", "12a"),
    (r"\bcat\b", "concat"),
    (r"\Bcat", "cat"),
    ("^b", "ab"),
    ("a$", "ab"),
    (r"^\w+$", "é"),
    ("^(a|b)*c$", "abab"),
]


@pytest.mark.parametrize("pattern,text", MATCH)
def test_matches(pattern, text):
    assert search(pattern, text) is True


@pytest.mark.parametrize("pattern,text", NO_MATCH)
def test_does_not_match(pattern, text):
    assert search(pattern, text) is False


@pytest.mark.parametrize("pattern", ["(", "(a", "a)", "[a", "*a", "a**", "[z-a]", "a{3,2}", "(?=a)", "\\"])
def test_invalid_patterns(pattern):
    with pytest.raises(RegexError):
        compile_pattern(pattern)


def test_no_catastrophic_backtracking():
    start = time.perf_counter()
    assert search("^(a+)+$", "a" * 5000 + "b") is False
    assert search("(x+x+)+y", "x" * 3000) is False
    assert time.perf_counter() - start < 20


def test_counted_repetition_is_expanded():
    assert search("^(ab){3}$", "ababab")
    assert not search("^(ab){3}$", "abab")
    assert search("^(?:a|b){2,4}c$", "abac")


def test_compile_is_cached():
    assert compile_pattern("a+b") is compile_pattern("a+b")
