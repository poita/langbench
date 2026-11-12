from textbuffer import Cursor, normalize


def test_selection_properties():
    c = Cursor((1, 2), anchor=(0, 5))
    assert (c.start, c.end) == ((0, 5), (1, 2))
    assert Cursor((1, 2), anchor=(1, 2)).anchor is None


def test_point_cursors_merge():
    out = normalize([Cursor((0, 1), primary=True), Cursor((0, 1))])
    assert len(out) == 1 and out[0].primary


def test_touching_selections_do_not_merge():
    a = Cursor((0, 0), anchor=(0, 2))
    b = Cursor((0, 4), anchor=(0, 2))
    assert len(normalize([a, b])) == 2


def test_point_on_selection_edge_merges():
    a = Cursor((0, 4), anchor=(0, 1))
    b = Cursor((0, 1))
    (m,) = normalize([a, b])
    assert (m.start, m.end, m.head) == ((0, 1), (0, 4), (0, 4))


def test_equal_range_keeps_first_goal():
    a = Cursor((1, 1), goal=7)
    b = Cursor((1, 1), goal=3)
    assert normalize([a, b])[0].goal == 7
