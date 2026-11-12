import pytest

from spreadsheet import CYCLE, DIV0, Sheet


def build(*commands):
    sheet = Sheet()
    for name, content in commands:
        sheet.set(name, content)
    return sheet


def test_example_cycle_created_and_broken():
    s = build(("A1", "10"), ("A2", "32"), ("A3", "=A1+A2"))
    assert s.get("A3") == "42"
    s.set("A1", "=A3")
    assert s.get("A1") == s.get("A3") == "#CYCLE!"
    s.set("A1", "5")
    assert s.get("A3") == "37"
    assert s.dump() == [("A1", "5"), ("A2", "32"), ("A3", "37")]


def test_example_strings_ranges_if_errors():
    s = build(
        ("A1", '"Total"'),
        ("B1", "3"),
        ("B2", "4.5"),
        ("B3", '"x"'),
        ("C1", "=SUM(B1:B3)"),
        ("C2", '=A1&": "&C1'),
        ("C3", '=IF(C1>7, "big", "small")'),
        ("C4", "=AVG(B1:B3)"),
        ("C5", "=COUNT(B1:B3)"),
        ("C6", "=B1/(B2-4.5)"),
        ("C7", "=C6+1"),
        ("C8", "=1/3"),
    )
    assert s.dump() == [
        ("A1", "Total"), ("B1", "3"), ("C1", "7.5"), ("B2", "4.5"),
        ("C2", "Total: 7.5"), ("B3", "x"), ("C3", "big"), ("C4", "3.75"),
        ("C5", "2"), ("C6", "#DIV/0!"), ("C7", "#DIV/0!"), ("C8", "0.3333333333"),
    ]  # fmt: skip
    assert s.value("C6") is DIV0


@pytest.mark.parametrize(
    "formula, shown",
    [
        ("=1+2*3", "7"),
        ("=-2*3-4", "-10"),
        ("=1<2+3", "1"),
        ("=1+2&3", "33"),
        ("=--5", "5"),
        ('="5"+1', "#VALUE!"),
        ('=1="1"', "0"),
        ('=1<>"1"', "1"),
        ('=1<"1"', "#VALUE!"),
        ('="B"<"a"', "1"),
        ('="ab">"a"', "1"),
        ('="\U0001f600"<"ｚ"', "0"),
        ("=Z1&\"x\"", "x"),
        ('=(Z1)=""', "1"),
        ("=-Z1&\"x\"", "0x"),
        ("=COUNT((Z1))", "0"),
        ("=IF(1,Z1,7)&\"x\"", "x"),
        ("=Z1", "0"),
        ("=1/0", "#DIV/0!"),
        ("=1/-0", "#DIV/0!"),
        ("=A0+1/0", "#REF!"),
        ("=IF(1,2,1/0)", "2"),
        ("=IF(0,1/0,3)", "3"),
        ('=IF("a",1,2)', "#VALUE!"),
        ("=SUM(1,2,3)", "6"),
        ("=MIN(Y1:Y3)", "0"),
        ("=AVG(Y1:Y3)", "#DIV/0!"),
        ("=100000000000000000000", "1e+20"),
    ],
)
def test_formula_values(formula, shown):
    s = Sheet()
    s.set("A1", formula)
    assert s.get("A1") == shown


def test_overflow_is_value_error():
    s = build(("A1", "=999999999999999999*1000000000000000000"))
    s.set("B1", "=A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1*A1")
    assert s.get("B1") == "#VALUE!"
    s.set("C1", "=SUM(B1)")
    assert s.get("C1") == "#VALUE!"


def test_sum_is_left_to_right_not_compensated():
    s = build(("A1", "0.1"), ("A2", "0.2"), ("A3", "0.3"), ("B1", "=SUM(A1:A3)"))
    assert s.value("B1") == 0.1 + 0.2 + 0.3  # 0.6000000000000001


def test_range_aggregates_skip_strings_and_empties_but_propagate_errors():
    s = build(("A1", "2"), ("A2", '"s"'), ("A4", "6"), ("B1", "=SUM(A1:A5)"))
    assert s.get("B1") == "8"
    s.set("A3", "=1/0")
    assert s.get("B1") == "#DIV/0!"
    s.set("B2", "=SUM(A1,A2)")  # expression argument that is a string
    assert s.get("B2") == "#VALUE!"


def test_self_reference_and_range_including_itself_are_cycles():
    s = build(("A1", "=A1+1"), ("B1", "=SUM(A1:C1)"))
    assert s.get("A1") == "#CYCLE!"
    assert s.get("B1") == "#CYCLE!"
    s.set("B1", "=SUM(A1:A1)")
    assert s.get("B1") == "#CYCLE!"  # reads cyclic A1
    s.set("A1", "1")
    assert s.get("B1") == "1"


def test_if_masks_cycle_of_unselected_branch():
    s = build(("A1", "=A1"), ("B1", "=IF(1,5,A1)"), ("C1", "=IF(0,5,A1)"))
    assert s.get("A1") == "#CYCLE!"
    assert s.get("B1") == "5"
    assert s.get("C1") == "#CYCLE!"


def test_edit_cleared_and_dependents_update():
    s = build(("A1", "1"), ("B1", "=A1+1"), ("C1", "=B1*2"))
    assert s.get("C1") == "4"
    s.clear("A1")
    assert s.get("A1") == ""
    assert s.get("C1") == "2"
    assert s.dump() == [("B1", "1"), ("C1", "2")]


def test_clear_cell_in_cycle_breaks_it():
    s = build(("A1", "=B1"), ("B1", "=A1"))
    assert s.get("A1") == "#CYCLE!"
    s.clear("B1")
    assert s.get("A1") == "0"


def test_empty_string_cell_is_non_empty():
    s = build(("A2", '""'))
    assert s.dump() == [("A2", "")]


def test_negative_zero_literal_displays_zero():
    s = build(("A1", "-0"), ("B1", "=-A1"))
    assert s.get("A1") == "0" and s.get("B1") == "0"


def test_long_chain_and_deep_expression():
    s = Sheet()
    s.set("A1", "1")
    for row in range(2, 5001):
        s.set(f"A{row}", f"=A{row - 1}+1")
    assert s.get("A5000") == "5000"
    s.set("A1", "10")
    assert s.get("A5000") == "5009"
    s.set("A1", "=A5000")
    assert s.get("A2500") == "#CYCLE!"
    s.set("B1", "=" + "(" * 100 + "1" + ")" * 100 + "+1" * 1500)
    assert s.get("B1") == "1501"


def test_invalid_cell_name_rejected():
    with pytest.raises(ValueError):
        Sheet().set("AAA1", "1")
