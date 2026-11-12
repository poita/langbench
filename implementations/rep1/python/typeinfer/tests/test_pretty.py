from typeinfer import format_type
from typeinfer.pretty import var_name
from typeinfer.typerep import BOOL, INT, TVar, arrow, list_of, tuple_of


def test_var_names():
    assert [var_name(i) for i in (0, 1, 25, 26, 27, 52, 315 * 26 + 2)] == [
        "'a", "'b", "'z", "'a1", "'b1", "'a2", "'c315",
    ]


def test_first_appearance_order():
    a, b = TVar(0), TVar(0)
    assert format_type(arrow(b, arrow(a, b))) == "'a -> 'b -> 'a"


def test_parenthesisation():
    f = arrow(INT, INT)
    assert format_type(arrow(f, INT)) == "(int -> int) -> int"
    assert format_type(arrow(INT, f)) == "int -> int -> int"
    assert format_type(tuple_of([f, tuple_of([INT, INT]), INT])) == "(int -> int) * (int * int) * int"
    assert format_type(arrow(tuple_of([INT, BOOL]), tuple_of([INT, BOOL]))) == "int * bool -> int * bool"
    assert format_type(list_of(list_of(INT))) == "int list list"
    assert format_type(list_of(f)) == "(int -> int) list"
    assert format_type(list_of(tuple_of([INT, BOOL]))) == "(int * bool) list"
    assert format_type(tuple_of([tuple_of([INT, INT]), INT])) == "(int * int) * int"
