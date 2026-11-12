import pytest

from fulltext.stemmer import stem


@pytest.mark.parametrize(
    "word, expected",
    [
        ("caresses", "caress"), ("ponies", "poni"), ("ties", "ti"), ("caress", "caress"),
        ("cats", "cat"), ("feed", "feed"), ("agreed", "agre"), ("need", "need"),
        ("bleed", "bleed"), ("plastered", "plaster"), ("bled", "bled"),
        ("motoring", "motor"), ("sing", "sing"), ("conflated", "conflat"),
        ("troubled", "troubl"), ("sized", "size"), ("hopping", "hop"),
        ("falling", "fall"), ("filing", "file"), ("failing", "fail"),
        ("happy", "happi"), ("sky", "sky"), ("relational", "relat"),
        ("conditional", "condit"), ("sensibility", "sensibl"),
        ("relativity", "rel"), ("probate", "probat"), ("rate", "rate"),
        ("cease", "ceas"), ("controll", "control"), ("roll", "roll"),
        ("running", "run"), ("runner", "runner"), ("connections", "connect"),
        ("abandoned", "abandon"), ("controlled", "control"), ("happier", "happier"),
        ("is", "is"), ("a", "a"), ("by", "by"),
    ],
)
def test_stems(word, expected):
    assert stem(word) == expected
