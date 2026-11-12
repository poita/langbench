import pytest

from mimedump.rfc2047 import decode_display, decode_unstructured, match_encoded_word

TAB = "\t"


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("=?utf-8?Q?caf=C3=A9?=", "café"),
        ("=?utf-8?Q?a?=   =?utf-8?Q?b?=", "ab"),
        ("x =?utf-8?Q?a?= y", "x a y"),
        ("=?utf-8?Q?a?=b", "ab"),
        ("=?iso-8859-1?Q?caf=E9?=", "café"),
        ("=?windows-1252?Q?smart=92quote?=", "smart’quote"),
        ("=?utf-8?B?SsO2cmc=?=", "Jörg"),
        ("=?utf-8*en?Q?hi?=", "hi"),
        ("=?utf-8?X?hi?=", "=?utf-8?X?hi?="),
        ("  plain    spaced   text  ", "plain    spaced   text"),
        (f"=?utf-8?Q?a?= {TAB} =?utf-8?Q?b?= {TAB} c", f"ab {TAB} c"),
        ("=?utf-8?Q?a_b?=", "a b"),
        ("=?utf-8?Q?a=ZZb?=", "a=ZZb"),
        ("=??Q?x?=", "=??Q?x?="),
        ("=?utf-8?Q?a b?=", "=?utf-8?Q?a b?="),
        ("=?=?utf-8?Q?a?=", "=?a"),
        ("=?x?q??=", ""),
    ],
)
def test_decode_unstructured(raw, expected):
    assert decode_unstructured(raw) == expected


def test_match_encoded_word_positions():
    assert match_encoded_word("xx=?utf-8?Q?a?=yy", 2) == ("a", 15)
    assert match_encoded_word("xx=?utf-8?Q?a?=yy", 0) is None


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("John Q. Public ", "John Q. Public"),
        ('"Doe, John" ', "Doe, John"),
        ("=?utf-8?B?SsO2cmc=?= ", "Jörg"),
        ("John (the third) Public ", "John   Public"),
        ('"=?utf-8?Q?x?="', "=?utf-8?Q?x?="),
        ("(c)(d)", ""),
        ('"a\\"b"', 'a"b'),
    ],
)
def test_decode_display(raw, expected):
    assert decode_display(raw) == expected
