import pytest

from fulltext.query import And, Atom, Not, Or, parse_query, positive_atoms

cat, dog, bird = Atom(("cat",)), Atom(("dog",)), Atom(("bird",))


@pytest.mark.parametrize(
    "text, tree",
    [
        ("cat", cat),
        ("cat dog", And((cat, dog))),
        ("cat AND dog", And((cat, dog))),
        ("cat OR dog", Or((cat, dog))),
        ("cat OR dog bird", Or((cat, And((dog, bird))))),
        ("NOT cat", Not(cat)),
        ("(cat OR dog) AND bird", And((Or((cat, dog)), bird))),
        ("cat AND", cat),
        ("OR cat", cat),
        ("cat ()", cat),
        ("cat NOT ()", cat),
        ("cat NOT (", cat),
        ("(cat", cat),
        ('"cat', cat),
        ("cat ) dog", cat),
        ("cat ) ) dog", cat),
        ("cat OR AND dog", Or((cat, dog))),
        ("cat AND OR dog", Or((cat, dog))),
        ("cat AND AND dog", And((cat, dog))),
        ("dog NOT ( cat", And((dog, Not(cat)))),
        ("NOT NOT cat", Not(cat, 2)),
        ('"well known"', Atom(("well", "known"))),
        ("well-known", Atom(("well", "known"))),
        ('"to be"', Atom(("to", "be"))),
    ],
)
def test_parse(text, tree):
    assert parse_query(text) == tree


@pytest.mark.parametrize("text", ["", "()", "the", "NOT", '""', '"the"', "a AND the", "-- !!"])
def test_empty_tree(text):
    assert parse_query(text) is None


def test_lowercase_operators_are_words():
    assert parse_query("cat or dog") == And((cat, Atom(("dog",))))


def test_positive_atoms():
    tree = parse_query("cat NOT dog (NOT NOT bird) NOT (NOT fish) cat")
    assert positive_atoms(tree) == [cat, bird, Atom(("fish",))]
    assert positive_atoms(None) == []
    assert positive_atoms(parse_query("NOT cat")) == []
