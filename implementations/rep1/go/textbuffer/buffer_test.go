package textbuffer

import (
	"reflect"
	"strings"
	"testing"
)

func heads(b *Buffer) []Position {
	var out []Position
	for _, c := range b.Cursors() {
		out = append(out, c.Head)
	}
	return out
}

func wantText(t *testing.T, b *Buffer, want string) {
	t.Helper()
	if got := b.Text(); got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
}

func wantHeads(t *testing.T, b *Buffer, want ...Position) {
	t.Helper()
	if got := heads(b); !reflect.DeepEqual(got, want) {
		t.Fatalf("cursors = %v, want %v", got, want)
	}
}

func TestNewAndAccessors(t *testing.T) {
	b := New("")
	if b.LineCount() != 1 || b.Line(0) != "" || b.CursorCount() != 1 {
		t.Fatalf("empty buffer: %d lines, %d cursors", b.LineCount(), b.CursorCount())
	}
	if c := b.Primary(); c.Head != (Position{}) || c.Selected || !c.Primary {
		t.Fatalf("initial cursor = %+v", c)
	}
	b = NewFromLines(nil)
	wantText(t, b, "")
	b = New("a\n\nb")
	if !reflect.DeepEqual(b.Lines(), []string{"a", "", "b"}) || b.LineLen(2) != 1 {
		t.Fatalf("lines = %q", b.Lines())
	}
	var sb strings.Builder
	if n, err := b.WriteTo(&sb); err != nil || n != 4 || sb.String() != "a\n\nb" {
		t.Fatalf("WriteTo = %d, %v, %q", n, err, sb.String())
	}
}

func TestSingleCursorEditing(t *testing.T) {
	b := New("hello world\nsecond line")
	b.Move(End, false)
	b.Insert("!")
	b.Move(Down, false)
	b.Insert(" (edited)")
	b.GoTo(0, 5)
	b.Insert(",")
	wantText(t, b, "hello, world!\nsecond line (edited)")
	wantHeads(t, b, Position{0, 6})
	b.Delete()
	b.Delete()
	wantText(t, b, "hell world!\nsecond line (edited)")
	wantHeads(t, b, Position{0, 4})
}

func TestDeleteJoinsLines(t *testing.T) {
	b := New("ab\ncd")
	b.GoTo(1, 0)
	b.Delete()
	wantText(t, b, "abcd")
	wantHeads(t, b, Position{0, 2})
	b = New("ab\ncd")
	b.GoTo(0, 2)
	b.DeleteForward()
	wantText(t, b, "abcd")
	wantHeads(t, b, Position{0, 2})
}

func TestEditsAtDocumentEdgesAreNotRecorded(t *testing.T) {
	b := New("x")
	b.Delete()
	b.Move(End, false)
	b.DeleteForward()
	if b.CanUndo() {
		t.Fatal("no-op edits must not create undo entries")
	}
	b.Insert("y")
	b.Undo()
	b.GoTo(0, 0)
	b.Delete() // no-op must not clear the redo stack
	if !b.CanRedo() {
		t.Fatal("no-op edit cleared the redo stack")
	}
}

func TestMultiCursorEdit(t *testing.T) {
	b := New("alpha\nbeta\ngamma")
	b.AddCursor(1, 0)
	b.AddCursor(2, 0)
	b.Insert("- ")
	wantText(t, b, "- alpha\n- beta\n- gamma")
	wantHeads(t, b, Position{0, 2}, Position{1, 2}, Position{2, 2})
	b.Move(End, true)
	b.Insert("X")
	wantText(t, b, "- X\n- X\n- X")
	b.GoTo(0, 1)
	b.Move(Right, true)
	b.Move(Right, true)
	b.Delete()
	wantText(t, b, "-\n- X\n- X")
	wantHeads(t, b, Position{0, 1})
}

func TestAdjacentCursorsSameLine(t *testing.T) {
	// Two adjacent cursors both deleting remove two characters and collide.
	b := New("abcdef")
	b.AddCursor(0, 3)
	b.AddCursor(0, 4)
	b.Delete()
	wantText(t, b, "abef")
	wantHeads(t, b, Position{0, 0}, Position{0, 2})
}

func TestSameLineInsertsShiftLaterCursors(t *testing.T) {
	b := New("abcdef")
	b.AddCursor(0, 2)
	b.AddCursor(0, 4)
	b.Insert("XY")
	wantText(t, b, "XYabXYcdXYef")
	wantHeads(t, b, Position{0, 2}, Position{0, 6}, Position{0, 10})
}

func TestMultilineInsertWithManyCursors(t *testing.T) {
	b := New("ab\ncd\nef")
	b.AddCursor(0, 1)
	b.AddCursor(1, 1)
	b.AddCursor(2, 2)
	b.Insert("1\n2")
	wantText(t, b, "1\n2a1\n2b\nc1\n2d\nef1\n2")
	wantHeads(t, b, Position{1, 1}, Position{2, 1}, Position{4, 1}, Position{6, 1})
}

func TestMoveCollapsesSelection(t *testing.T) {
	b := New("abcdef")
	b.GoTo(0, 4)
	b.Move(Left, true)
	b.Move(Left, true) // head 2, anchor 4 (backward)
	if c := b.Primary(); !c.Selected || !c.Backward() || c.Anchor != (Position{0, 4}) {
		t.Fatalf("cursor = %+v", c)
	}
	b.Move(Right, false)
	wantHeads(t, b, Position{0, 4})
	b.Move(Left, true)
	b.Move(Right, true) // selection shrinks to nothing
	if b.Primary().Selected {
		t.Fatal("empty selection must be dropped")
	}
	b.Move(Left, true)
	b.Move(Left, false)
	wantHeads(t, b, Position{0, 3})
}

func TestGoalColumn(t *testing.T) {
	b := New("0123456789\nab\n0123456789")
	b.GoTo(0, 8)
	b.Move(Down, false)
	wantHeads(t, b, Position{1, 2})
	b.Move(Down, false)
	wantHeads(t, b, Position{2, 8})
	b.Move(Down, false) // last line: goes to the end, goal becomes 10
	wantHeads(t, b, Position{2, 10})
	b.Move(Up, false)
	b.Move(Up, false)
	wantHeads(t, b, Position{0, 10})
	b.Move(Up, false) // first line: goes to the start, goal becomes 0
	wantHeads(t, b, Position{0, 0})
	b.Move(Down, false)
	wantHeads(t, b, Position{1, 0})
	b.Move(Right, false) // any other command resets the goal
	b.Move(Down, false)
	wantHeads(t, b, Position{2, 1})
}

func TestGoalColumnResetByNoOps(t *testing.T) {
	b := New("0123456789\nab\n0123456789")
	b.GoTo(0, 8)
	b.Move(Down, false) // (1,2), goal 8
	b.Redo()            // nothing to redo, but resets the goal to 2
	b.Move(Down, false)
	wantHeads(t, b, Position{2, 2})
}

func TestClearCursorsKeepsPrimarySelection(t *testing.T) {
	b := New("abc\ndef")
	b.Move(Right, true)
	b.AddCursor(1, 1)
	if b.CursorCount() != 2 {
		t.Fatal("want two cursors")
	}
	b.ClearCursors()
	if b.CursorCount() != 1 || !b.Primary().Selected || b.SelectedText(0) != "a" {
		t.Fatalf("cursors = %+v", b.Cursors())
	}
	b.AddCursor(0, 0) // inside the selection: merges
	if b.CursorCount() != 1 {
		t.Fatalf("cursors = %+v", b.Cursors())
	}
}

func TestAddCursorMergesAndClamps(t *testing.T) {
	b := New("abc")
	b.AddCursor(0, 0)
	if b.CursorCount() != 1 {
		t.Fatal("cursor on a cursor must merge")
	}
	b.AddCursor(1_000_000_000, 1_000_000_000)
	wantHeads(t, b, Position{0, 0}, Position{0, 3})
	if b.Cursors()[1].Primary {
		t.Fatal("added cursor must not be primary")
	}
}

func TestUndoRedo(t *testing.T) {
	b := New("abc")
	b.Move(End, false)
	b.Insert("d\ne")
	wantText(t, b, "abcd\ne")
	b.Delete()
	b.Delete()
	wantText(t, b, "abcd")
	b.Undo()
	wantText(t, b, "abcd\n")
	wantHeads(t, b, Position{1, 0})
	b.Undo()
	wantText(t, b, "abcd\ne")
	wantHeads(t, b, Position{1, 1})
	b.Redo()
	wantText(t, b, "abcd\n")
	b.Insert("Z")
	if b.CanRedo() {
		t.Fatal("an edit must clear the redo stack")
	}
	if b.Redo() {
		t.Fatal("redo should report nothing to do")
	}
	wantText(t, b, "abcd\nZ")
	for b.Undo() {
	}
	wantText(t, b, "abc")
	wantHeads(t, b, Position{0, 3})
	for b.Redo() {
	}
	wantText(t, b, "abcd\nZ")
}

func TestUndoRestoresWholeCursorSet(t *testing.T) {
	b := New("one\ntwo\nthree")
	b.AddCursor(1, 1)
	b.AddCursor(2, 5)
	b.Move(Left, true)
	before := b.Cursors()
	b.Insert("#")
	after := b.Cursors()
	b.GoTo(0, 0) // cursor-only commands are overridden by undo
	b.Undo()
	wantText(t, b, "one\ntwo\nthree")
	if got := b.Cursors(); !reflect.DeepEqual(got, before) {
		t.Fatalf("after undo: %+v, want %+v", got, before)
	}
	b.Redo()
	if got := b.Cursors(); !reflect.DeepEqual(got, after) {
		t.Fatalf("after redo: %+v, want %+v", got, after)
	}
}

func TestSelectionReplacement(t *testing.T) {
	b := New("hello world")
	b.Move(Right, true)
	b.Move(Right, true)
	b.Insert("J")
	wantText(t, b, "Jllo world")
	b.Move(End, true)
	if got := b.SelectedText(0); got != "llo world" {
		t.Fatalf("selected %q", got)
	}
	b.DeleteForward()
	wantText(t, b, "J")
}

func TestDirectionParsing(t *testing.T) {
	for _, d := range []Direction{Left, Right, Up, Down, Home, End} {
		got, err := ParseDirection(d.String())
		if err != nil || got != d {
			t.Errorf("round trip %v: %v, %v", d, got, err)
		}
	}
	if _, err := ParseDirection("sideways"); err == nil {
		t.Error("want an error for an unknown direction")
	}
}

func TestLongLineEdits(t *testing.T) {
	long := strings.Repeat("x", 200_000)
	b := New(long)
	b.GoTo(0, 100_000)
	for i := 0; i < 1000; i++ {
		b.Insert("ab")
		b.Delete()
	}
	if b.LineLen(0) != 200_000+1000 {
		t.Fatalf("length = %d", b.LineLen(0))
	}
}
