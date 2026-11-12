import pytest

from fulltext.analysis import analyze, fold, token_spans, token_texts


@pytest.mark.parametrize(
    "text, tokens",
    [
        ("The cat sat.", ["the", "cat", "sat"]),
        ("don't stop", ["dont", "stop"]),
        ("'quoted'", ["quoted"]),
        ("rock'n'roll", ["rocknroll"]),
        ("a''b", ["a", "b"]),
        ("well-known", ["well", "known"]),
        ("Version 1.2.3", ["version", "1", "2", "3"]),
        ("X1 XY2Z", ["x1", "xy2z"]),
        ("Don’t", ["dont"]),
        ("Café CAFÉ", ["café", "cafÉ"]),
        ("a × b ÷ c", ["a", "b", "c"]),
        ("日本語 text", ["text"]),
    ],
)
def test_token_texts(text, tokens):
    assert token_texts(text) == tokens


def test_fold():
    assert fold("Don’t") == "dont"


def test_terms_stem_only_ascii_letters():
    assert analyze("Running runs x1 café") == ["run", "run", "x1", "café"]


def test_token_spans():
    starts, ends = token_spans("ab, cd'e")
    assert list(starts) == [0, 4]
    assert list(ends) == [2, 8]
