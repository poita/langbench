from textbuffer import TextBuffer


def heads(buf):
    return [c.head for c in buf.cursors]


def test_insert_and_backspace():
    buf = TextBuffer("ab")
    buf.move("end")
    buf.insert("c\nd")
    assert buf.text == "abc\nd" and heads(buf) == [(1, 1)]
    buf.delete()
    buf.delete()
    assert buf.text == "abc" and heads(buf) == [(0, 3)]
    buf.delete_forward()
    assert buf.text == "abc"


def test_no_op_edit_records_nothing():
    buf = TextBuffer("x")
    buf.delete()
    assert not buf.can_undo
    buf.insert("a")
    buf.undo()
    buf.delete()
    assert buf.can_redo


def test_multi_cursor_adjacent_delete_merges():
    buf = TextBuffer("abcdef")
    buf.goto(0, 3)
    buf.add_cursor(0, 4)
    buf.delete()
    assert buf.text == "abef" and heads(buf) == [(0, 2)]


def test_multi_cursor_newline_positions():
    buf = TextBuffer("ab\ncd")
    buf.goto(0, 1)
    buf.add_cursor(0, 2)
    buf.add_cursor(1, 1)
    buf.insert("\n")
    assert buf.lines == ("a", "b", "", "c", "d")
    assert heads(buf) == [(1, 0), (2, 0), (4, 0)]
    buf.undo()
    assert buf.text == "ab\ncd"
    assert heads(buf) == [(0, 1), (0, 2), (1, 1)]
    buf.redo()
    assert heads(buf) == [(1, 0), (2, 0), (4, 0)]


def test_goal_column_and_edges():
    buf = TextBuffer("abcdef\nab\nabcdef")
    buf.goto(0, 5)
    buf.move("down")
    assert heads(buf) == [(1, 2)]
    buf.move("down")
    assert heads(buf) == [(2, 5)]
    buf.move("down")
    assert heads(buf) == [(2, 6)]
    buf.move("up")
    assert heads(buf) == [(1, 2)]


def test_selection_collapse_and_extend():
    buf = TextBuffer("abcdef")
    buf.goto(0, 2)
    buf.move("right", select=True)
    buf.move("right", select=True)
    assert buf.cursors[0].anchor == (0, 2)
    buf.move("left")
    assert heads(buf) == [(0, 2)] and buf.cursors[0].anchor is None
    buf.move("left", select=True)
    buf.move("right", select=True)
    assert buf.cursors[0].anchor is None


def test_selection_edit_and_undo_restores_cursors():
    buf = TextBuffer("hello world")
    buf.move("end", select=True)
    before = buf.cursors[0].state
    buf.insert("X")
    assert buf.text == "X"
    buf.undo()
    assert buf.text == "hello world" and buf.cursors[0].state == before


def test_clear_cursors_keeps_primary_selection():
    buf = TextBuffer("abc\ndef")
    buf.move("right", select=True)
    buf.add_cursor(1, 1)
    buf.clear_cursors()
    assert len(buf.cursors) == 1 and buf.cursors[0].anchor == (0, 0)


def test_redo_cleared_by_new_edit():
    buf = TextBuffer("")
    buf.insert("a")
    buf.undo()
    buf.insert("b")
    buf.redo()
    assert buf.text == "b"


def test_render():
    buf = TextBuffer("a\nb")
    assert buf.render() == "a\nb\ncursor 0 0\n--\n"
