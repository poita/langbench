import pytest

from spreadsheet import syntax as ast
from spreadsheet.parser import parse_formula
from spreadsheet.refs import cell_name, make_key, parse_ref
from spreadsheet.values import REF


def test_precedence_tree():
    root = parse_formula("1+2*3").root
    assert isinstance(root, ast.Arith) and root.op == "+"
    assert isinstance(root.right, ast.Arith) and root.right.op == "*"


def test_left_associativity():
    root = parse_formula("1-2-3").root
    assert isinstance(root.left, ast.Arith)
    assert root.right == ast.Literal(3.0)


def test_range_dependencies_include_every_cell_either_corner_order():
    f = parse_formula("SUM(B2:A1)")
    assert f.root.args == (ast.Range(1, 1, 2, 2),)
    assert f.deps == {parse_ref(n) for n in ("A1", "B1", "A2", "B2")}


def test_dependencies_of_both_if_branches():
    f = parse_formula("IF(A1,B1,C1)")
    assert f.deps == {parse_ref(n) for n in ("A1", "B1", "C1")}


@pytest.mark.parametrize(
    "text", ["AAA1+1", "A0", "A10000", "A01", "IF(1,2,A0)", "SUM(A1:AAA1)", "B1+A1+A01"]
)
def test_invalid_reference_collapses_to_ref_error(text):
    f = parse_formula(text)
    assert f.root == ast.Literal(REF)
    assert f.deps == frozenset()


def test_spaces_are_ignored():
    assert parse_formula(" 1 + 2 ").root == parse_formula("1+2").root


@pytest.mark.parametrize("name", ["A1", "Z9999", "AA1", "ZZ9999", "AB123"])
def test_cell_name_roundtrip(name):
    assert cell_name(parse_ref(name)) == name


@pytest.mark.parametrize("name", ["", "A", "1", "a1", "AAA1", "A0", "A01", "A10000"])
def test_parse_ref_rejects(name):
    assert parse_ref(name) is None


def test_keys_sort_row_major():
    assert make_key(1, 702) < make_key(2, 1)
