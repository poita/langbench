import pytest

import btregex


def run(pattern, subject):
    m = btregex.compile(pattern).search(subject)
    if m is None:
        return None
    return (m.start, m.end) + tuple(m.spans)


@pytest.mark.parametrize(
    "pattern, subject, expected",
    [
        # SPEC examples
        ("(a|ab)(c|bcd)(d*)", "abcd", (0, 4, (0, 1), (1, 4), (4, 4))),
        ("a*", "bbb", (0, 0)),
        ("a*", "", (0, 0)),
        ("^(a+)+$", "aaaa", (0, 4, (0, 4))),
        ("^(a+)+$", "aaab", None),
        ("(a|(b))+", "ba", (0, 2, (1, 2), (0, 1))),
        ("(a|(b))+", "ab", (0, 2, (1, 2), (1, 2))),
        (r"[^a-c]\d{2,3}x?", "zz123xx", (1, 6)),
        (r"[^a-c]\d{2,3}x?", "abc9", None),
        ("(a*)*b", "aab", (0, 3, (2, 2))),
        ("(a*)*b", "ccc", None),
        ("x$|^(y)?z", "xz", None),
        ("x$|^(y)?z", "yz", (0, 2, (0, 1))),
        ("x$|^(y)?z", "zzz", (0, 1, None)),
        ("(a){0}b|(c)?(d)", "xb", (1, 2, None, None, None)),
        ("(a){0}b|(c)?(d)", "xcd", (1, 3, None, (1, 2), (2, 3))),
        ("(a){0}b|(c)?(d)", "d", (0, 1, None, None, (0, 1))),
        # ordered choice / greediness
        ("a|ab", "ab", (0, 1)),
        ("a+", "aaa", (0, 3)),
        ("a{2,3}", "aaaa", (0, 3)),
        ("a{2,}", "aaaa", (0, 4)),
        ("a{0,0}b", "ab", (1, 2)),
        # required iterations run even when empty
        ("(a*){3}", "", (0, 0, (0, 0))),
        # empty optional iteration ends the loop
        ("(a?)*b", "b", (0, 1, (0, 0))),
        ("(|a)+", "aaa", (0, 0, (0, 0))),
        ("(a|)+", "aaa", (0, 3, (3, 3))),
        # anchors
        ("a^b", "ab", None),
        ("^a", "ba", None),
        ("a$", "aba", (2, 3)),
        ("$", "abc", (3, 3)),
        ("^", "abc", (0, 0)),
        # escapes and classes
        (r"\.", "a.b", (1, 2)),
        (r"\w+", "  ab_1 ", (2, 6)),
        (r"\S+", "  ab  ", (2, 4)),
        (r"\D\d", "a1", (0, 2)),
        (r"[\w-]+", "a-b c", (0, 3)),
        (r"[a\-z]+", "-az", (0, 3)),
        ("[a-c-]+", "a-c", (0, 3)),
        # spaces are ordinary
        (" a ", "x a y", (1, 4)),
        # captures are undone on abandoned paths
        ("(a)b|(a)c", "ac", (0, 2, None, (0, 1))),
        ("((a)|b)*c", "abc", (0, 3, (1, 2), (0, 1))),
        # nested groups in counted repetition
        ("((a)|(b)){2}", "ab", (0, 2, (1, 2), (0, 1), (1, 2))),
    ],
)
def test_search(pattern, subject, expected):
    got = run(pattern, subject)
    if expected is None:
        assert got is None
    else:
        assert got == expected


def test_unset_groups_when_no_groups_pattern():
    m = btregex.compile("ab").search("xab")
    assert (m.start, m.end, m.spans) == (1, 3, ())


def test_state_does_not_leak_between_searches():
    rx = btregex.compile("(a)|b")
    assert rx.search("a").spans == ((0, 1),)
    assert rx.search("b").spans == (None,)
    assert rx.search("c") is None
    assert rx.search("b").spans == (None,)


def test_first_char_skipping_agrees_with_full_scan():
    # 'a' cannot start a match of x+y, so starts are filtered; result unchanged.
    assert run("x+y", "aaxxy") == (2, 5)
    assert run("x|", "ab") == (0, 0)


def test_deep_backtracking_on_long_subject():
    subject = "ab" * 5000
    m = btregex.compile("(a|b)*").search(subject)
    assert (m.start, m.end, m.spans) == (0, 10000, ((9999, 10000),))
    assert btregex.compile(".*b").search(subject).end == 10000


def test_pathological_patterns_terminate_quickly():
    assert btregex.compile("(a*)*b").search("a" * 12) is None
    assert btregex.compile("(a|aa)+c").search("a" * 18) is None


def test_match_api():
    m = btregex.compile("(a)(b)?").search("xa")
    assert m.span() == (1, 2)
    assert m.span(1) == (1, 2)
    assert m.span(2) is None
    assert m == btregex.compile("(a)(b)?").search("xa")
