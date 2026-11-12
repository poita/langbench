import pytest

import btregex


def spans(pattern, subject):
    m = btregex.search(pattern, subject)
    if m is None:
        return None
    return (m.start, m.end) + m.groups


@pytest.mark.parametrize("pattern, subject, expected", [
    # Spec worked examples
    (r"(a|ab)(c|bcd)(d*)", "abcd", (0, 4, (0, 1), (1, 4), (4, 4))),
    ("a*", "bbb", (0, 0)),
    ("a*", "", (0, 0)),
    (r"^(a+)+$", "aaaa", (0, 4, (0, 4))),
    (r"^(a+)+$", "aaab", None),
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
    # Semantics
    ("a|ab", "ab", (0, 1)),
    ("(a*){3}", "", (0, 0, (0, 0))),
    ("a^b", "ab", None),
    ("^$", "", (0, 0)),
    ("(a|b)*c", "abac", (0, 4, (2, 3))),
    ("(a*)+", "b", (0, 0, (0, 0))),
    ("(a?)*", "", (0, 0, (0, 0))),
    ("(|a)+", "aaa", (0, 0, (0, 0))),
    ("(a|)+", "aaa", (0, 3, (3, 3))),
    ("a{2,3}", "aaaa", (0, 3)),
    ("(ab){2,}", "ababab", (0, 6, (4, 6))),
    ("a{0}", "a", (0, 0)),
    ("(x+x+)+y", "xxxxxxxxxxxxxxxxxxxx", None),
    (r"\w+@\w+\.com", "mail bob@example.com now", (5, 20)),
    (r"[\d.]+", "v1.25.3!", (1, 7)),
    ("a.c", "a c", (0, 3)),
    (r"\ \-\@", " -@", (0, 3)),
    (r"\S+", "  ab ", (2, 4)),
    ("((a)|(b))*", "ab", (0, 2, (1, 2), (0, 1), (1, 2))),
])
def test_search(pattern, subject, expected):
    assert spans(pattern, subject) == expected


def test_match_api():
    m = btregex.compile("(b)(x)?").search("abc")
    assert m.span() == (1, 2) and m.span(1) == (1, 2) and m.span(2) is None
    assert m.group() == "b" and m.group(1) == "b" and m.group(2) is None
    with pytest.raises(IndexError):
        m.span(3)
    assert btregex.compile("(b)(x)?").group_count == 2


def test_deep_backtracking_does_not_recurse():
    subject = "a" * 10000
    m = btregex.search("(a|b)*$", subject)
    assert m.span() == (0, 10000)
    assert btregex.search(".*b", subject) is None
    assert btregex.search("(.)*c", subject + "c").span() == (0, 10001)


def test_nested_groups_deeply():
    depth = 120
    pattern = "(" * depth + "a" + ")" * depth
    m = btregex.search(pattern, "a")
    assert m.groups == ((0, 1),) * depth


def test_oracle_agreement_fixed_corpus():
    from oracle import oracle_search
    patterns = ["(a|ab)(c|bcd)(d*)", "(a*)*b", "(a|(b))+", "((a*)|b)*c", "(a?){2,4}b",
                "(|a)*x", "(a|aa)+c", "((a)|b){1,3}$", "(a{0,2}){2}"]
    subjects = ["", "a", "ab", "abcd", "aab", "baab", "aaaac", "bbbc", "abab",
                "aaaa"]
    for p in patterns:
        for s in subjects:
            expected = oracle_search(p, s)
            got = btregex.search(p, s)
            if expected is None:
                assert got is None, (p, s)
            else:
                assert got is not None, (p, s)
                assert (got.span(), got.groups) == expected, (p, s)
