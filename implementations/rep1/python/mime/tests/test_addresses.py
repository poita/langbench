import pytest

from mimedump.addresses import parse_address_list


def parse(value):
    return [(a.display, a.spec) for a in parse_address_list(value)]


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("Real Name <user@example.com>", [("Real Name", "user@example.com")]),
        ("user@example.com (Real Name)", [("", "user@example.com")]),
        ('"Doe, John" <jd@x.com>', [("Doe, John", "jd@x.com")]),
        ("a@b.com, (c) d@e.com", [("", "a@b.com"), ("", "d@e.com")]),
        ("Undisclosed recipients:;", []),
        ("grp: a@b.com, c@d.com;", [("", "a@b.com"), ("", "c@d.com")]),
        ("=?utf-8?B?SsO2cmc=?= <j@x.de>", [("Jörg", "j@x.de")]),
        ("foo (c (nested)) <a@b>", [("foo", "a@b")]),
        ("ed <a@[10.0.0.1]>", [("ed", "a@[10.0.0.1]")]),
        ("broken <a@@b>", [("", "broken<a@@b>")]),
        ("John Q. Public <jqp@example.com>", [("John Q. Public", "jqp@example.com")]),
        ("Symantec Email Proxy", [("", "SymantecEmailProxy")]),
        ('"=?utf-8?Q?x?=" <a@b>', [("=?utf-8?Q?x?=", "a@b")]),
        (
            "a <b <c@d.com> , e@f.com>, g@h.com",
            [("", "a<b<c@d.com>,e@f.com>"), ("", "g@h.com")],
        ),
        ("John (the third) Public <jqp@x.com>", [("John   Public", "jqp@x.com")]),
        ('"a b"@x.com', [("", "a b@x.com")]),
        ("a.b.c@d.e.f", [("", "a.b.c@d.e.f")]),
        ("a..b@c", [("", "a..b@c")]),
        ("postmaster", [("", "postmaster")]),
        ("<>", [("", "<>")]),
        ("", []),
        (" , ,", []),
        ("x <a@b> trailing junk", [("x", "a@b")]),
    ],
)
def test_parse_address_list(value, expected):
    assert parse(value) == expected
