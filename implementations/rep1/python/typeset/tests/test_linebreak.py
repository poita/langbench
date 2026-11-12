from typeset.hlist import BOX, GLUE, PENALTY, Item
from typeset.linebreak import BreakParams, break_lines, breakpoints


def words(*widths, glue=(2540, 1270, 850)):
    items = []
    for k, w in enumerate(widths):
        if k:
            items.append(Item(GLUE, width=glue[0], stretch=glue[1], shrink=glue[2]))
        items.append(Item(BOX, width=w, text="x"))
    items += [Item(PENALTY, penalty=10000), Item(GLUE, inf=True), Item(PENALTY, penalty=-10000)]
    return items


def test_breakpoints_need_a_box_before_glue():
    items = words(10, 20)
    assert breakpoints(items) == [1, 5]


def test_single_line_has_zero_badness():
    r = break_lines(words(15630, 22240, 25140, 15810), 160000, 18000, BreakParams())
    assert len(r.lines) == 1 and r.total_demerits == 100 and not r.emergency


def test_spec_example_6_prefers_tight_break():
    w = [15630, 22240, 25140, 13280, 24600, 17390, 12370, 16370, 17480]
    r = break_lines(words(*w), 160000, 18000, BreakParams())
    assert [b for _, b in r.lines][0] == 13  # after "the"
    assert r.total_demerits == 3016


def test_emergency_pass_when_nothing_is_feasible():
    r = break_lines(words(300000, 300000), 100000, 0, BreakParams())
    assert r.emergency
    assert len(r.lines) == 1  # fewest lines wins
