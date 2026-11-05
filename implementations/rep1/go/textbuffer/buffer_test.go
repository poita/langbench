package textbuffer

import (
	"fmt"
	"math/rand"
	"slices"
	"strings"
	"testing"
)

// heads renders the cursor heads as "l:c ..." for compact assertions.
func heads(b *Buffer) string {
	var parts []string
	for _, c := range b.Cursors() {
		parts = append(parts, itoa(c.Head.Line)+":"+itoa(c.Head.Col))
	}
	return strings.Join(parts, " ")
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	for ; n > 0; n /= 10 {
		s = string(rune('0'+n%10)) + s
	}
	return s
}

func checkState(t *testing.T, b *Buffer, text, cursors string) {
	t.Helper()
	if got := b.Text(); got != text {
		t.Errorf("text = %q, want %q", got, text)
	}
	if got := heads(b); got != cursors {
		t.Errorf("cursors = %q, want %q", got, cursors)
	}
}

func TestNewAndAccessors(t *testing.T) {
	b := New()
	checkState(t, b, "", "0:0")
	if b.LineCount() != 1 || b.NumCursors() != 1 || !b.Cursor(0).Primary {
		t.Error("empty buffer wrong")
	}
	b = NewFromText("ab\n\ncd")
	if b.LineCount() != 3 || string(b.Line(2)) != "cd" {
		t.Error("NewFromText wrong")
	}
	src := []byte("xy")
	b = NewFromLines([][]byte{src})
	src[0] = 'Z'
	if b.Text() != "xy" {
		t.Error("NewFromLines must copy")
	}
}

func TestClampAndGoto(t *testing.T) {
	b := New("abc", "de")
	if got := b.Clamp(99, 99); got != pt(1, 2) {
		t.Errorf("clamp = %v", got)
	}
	if got := b.Clamp(-1, -1); got != pt(0, 0) {
		t.Errorf("clamp = %v", got)
	}
	b.AddCursor(1, 1)
	b.Goto(0, 99)
	checkState(t, b, "abc\nde", "0:3")
}

func TestInsertAndDelete(t *testing.T) {
	b := New("hello world", "second line")
	b.Move(End, false)
	b.InsertString("!")
	b.Move(Down, false)
	b.InsertString(" (edited)")
	b.Goto(0, 5)
	b.InsertString(",")
	checkState(t, b, "hello, world!\nsecond line (edited)", "0:6")
	b.Delete()
	b.Delete()
	checkState(t, b, "hell world!\nsecond line (edited)", "0:4")
	b.DeleteForward()
	checkState(t, b, "hellworld!\nsecond line (edited)", "0:4")
}

func TestDeleteJoinsLines(t *testing.T) {
	b := New("ab", "cd")
	b.Goto(1, 0)
	b.Delete()
	checkState(t, b, "abcd", "0:2")
	b = New("ab", "cd")
	b.Goto(0, 2)
	b.DeleteForward()
	checkState(t, b, "abcd", "0:2")
}

func TestEditNoOps(t *testing.T) {
	b := New("x")
	b.Delete() // at start
	b.Goto(0, 1)
	b.DeleteForward() // at end
	b.Insert(nil)
	if b.CanUndo() {
		t.Error("no-op edits must not record history")
	}
	b.InsertString("a")
	b.Undo()
	b.Goto(0, 0)
	b.Delete() // no-op: must keep the redo stack
	if !b.CanRedo() {
		t.Error("no-op edit cleared redo")
	}
}

func TestMultiCursorColumnEdit(t *testing.T) {
	b := New("alpha", "beta", "gamma")
	b.AddCursor(1, 0)
	b.AddCursor(2, 0)
	b.InsertString("- ")
	checkState(t, b, "- alpha\n- beta\n- gamma", "0:2 1:2 2:2")
	b.Move(End, true)
	b.InsertString("X")
	checkState(t, b, "- X\n- X\n- X", "0:3 1:3 2:3")
	b.Goto(0, 1)
	b.Move(Right, true)
	b.Move(Right, true)
	b.Delete()
	checkState(t, b, "-\n- X\n- X", "0:1")
}

func TestMultiCursorSameLineAndNewlines(t *testing.T) {
	b := New("abcdef")
	b.AddCursor(0, 2)
	b.AddCursor(0, 4)
	b.InsertString("\n")
	checkState(t, b, "\nab\ncd\nef", "1:0 2:0 3:0")
}

func TestAdjacentDeletesMerge(t *testing.T) {
	b := New("abcdef")
	b.Goto(0, 3)
	b.AddCursor(0, 4)
	b.Delete()
	checkState(t, b, "abef", "0:2")
	if b.NumCursors() != 1 {
		t.Error("cursors should have merged")
	}
	b.Undo()
	checkState(t, b, "abcdef", "0:3 0:4")
}

func TestMoveBasics(t *testing.T) {
	b := New("ab", "", "cdef")
	b.Move(Left, false) // at start: unchanged
	checkState(t, b, "ab\n\ncdef", "0:0")
	b.Move(Right, false)
	b.Move(Right, false)
	b.Move(Right, false) // wraps to next line
	checkState(t, b, "ab\n\ncdef", "1:0")
	b.Move(Left, false)
	checkState(t, b, "ab\n\ncdef", "0:2")
	b.Move(Home, false)
	checkState(t, b, "ab\n\ncdef", "0:0")
	b.Move(Up, false)
	checkState(t, b, "ab\n\ncdef", "0:0")
	b.Goto(2, 4)
	b.Move(Down, false)
	checkState(t, b, "ab\n\ncdef", "2:4")
}

func TestGoalColumn(t *testing.T) {
	b := New("abcdef", "ab", "abcdef")
	b.Goto(0, 5)
	b.Move(Down, false)
	b.Move(Down, false)
	checkState(t, b, "abcdef\nab\nabcdef", "2:5")
	b.Move(Up, false)
	b.Move(Left, false) // resets goal to 1
	b.Move(Down, false)
	checkState(t, b, "abcdef\nab\nabcdef", "2:1")
	b.Goto(1, 2)
	b.Move(Up, false)
	b.Move(Up, false) // top edge: column 0, goal 0
	b.Move(Down, false)
	checkState(t, b, "abcdef\nab\nabcdef", "1:0")
}

func TestSelectionMoves(t *testing.T) {
	b := New("hello")
	b.Move(Right, true)
	b.Move(Right, true)
	if c := b.Cursor(0); !c.HasSelection || c.Anchor != pt(0, 0) || c.Head != pt(0, 2) {
		t.Errorf("selection = %+v", c)
	}
	b.Move(Left, true)
	b.Move(Left, true) // back at the anchor: selection vanishes
	if b.Cursor(0).HasSelection {
		t.Error("selection should be empty")
	}
	b.Move(End, true)
	b.Move(Left, false) // collapse to start
	checkState(t, b, "hello", "0:0")
	b.Move(End, true)
	b.Move(Right, false) // collapse to end
	checkState(t, b, "hello", "0:5")
}

func TestClearCursorsKeepsPrimarySelection(t *testing.T) {
	b := New("abc", "def")
	b.Goto(0, 0)
	b.Move(Right, true)
	b.AddCursor(1, 2)
	b.ClearCursors()
	if b.NumCursors() != 1 || !b.Cursor(0).HasSelection || !b.Cursor(0).Primary {
		t.Errorf("cursors = %+v", b.Cursors())
	}
}

func TestAddCursorMergesInsideSelection(t *testing.T) {
	b := New("abcdef")
	b.Move(End, true)
	b.AddCursor(0, 3)
	if b.NumCursors() != 1 || !b.Cursor(0).Primary {
		t.Errorf("cursors = %+v", b.Cursors())
	}
}

func TestMergedCursorKeepsFirstGoalOnVerticalMove(t *testing.T) {
	b := New("abcdefgh", "ab", "abcdefgh")
	b.Goto(0, 6)
	b.AddCursor(0, 3)
	b.Move(Down, false)
	// Both land on (1,2); the cursor that came first in cursor order (col 3)
	// has goal 3, the other 6.
	if b.NumCursors() != 1 || b.Cursor(0).Goal != 3 {
		t.Errorf("cursors = %+v", b.Cursors())
	}
	b.Move(Down, false)
	checkState(t, b, b.Text(), "2:3")
}

func TestUndoRedo(t *testing.T) {
	b := New("abc")
	b.Move(End, false)
	b.InsertString("d\ne")
	checkState(t, b, "abcd\ne", "1:1")
	b.Delete()
	b.Delete()
	checkState(t, b, "abcd", "0:4")
	b.Undo()
	checkState(t, b, "abcd\n", "1:0")
	b.Undo()
	checkState(t, b, "abcd\ne", "1:1")
	b.Redo()
	checkState(t, b, "abcd\n", "1:0")
	b.InsertString("Z")
	if b.Redo() {
		t.Error("redo after new edit must do nothing")
	}
	checkState(t, b, "abcd\nZ", "1:1")
	for b.Undo() {
	}
	checkState(t, b, "abc", "0:3")
	if b.Undo() {
		t.Error("undo on empty stack reported success")
	}
	for b.Redo() {
	}
	checkState(t, b, "abcd\nZ", "1:1")
}

func TestUndoRestoresSelectionsAndMultiCursor(t *testing.T) {
	b := New("one", "two", "three")
	b.AddCursor(1, 0)
	b.AddCursor(2, 0)
	b.Move(End, true)
	before := b.Cursors()
	b.InsertString("X\nY")
	b.Undo()
	if b.Text() != "one\ntwo\nthree" || !slices.EqualFunc(before, b.Cursors(),
		func(a, c Cursor) bool { a.Goal, c.Goal = 0, 0; return a == c }) {
		t.Errorf("after undo: %q %+v", b.Text(), b.Cursors())
	}
	b.Redo()
	checkState(t, b, "X\nY\nX\nY\nX\nY", "1:1 3:1 5:1")
}

// model is a deliberately naive implementation (absolute offsets over one
// string) used to cross-check Buffer with random operations on single cursors
// and multiple point cursors.
type model struct {
	text    string
	cursors []int // offsets, sorted, distinct, point cursors
}

func (m *model) edit(del int, ins string) {
	// del: 0 insert, -1 backspace, +1 delete-forward
	var out []int
	shift := 0
	for _, o := range m.cursors {
		o += shift
		s, e := o, o
		switch {
		case del < 0 && o > 0:
			s--
		case del > 0 && o < len(m.text):
			e++
		case del != 0:
			out = append(out, o)
			continue
		}
		m.text = m.text[:s] + ins + m.text[e:]
		shift += len(ins) - (e - s)
		out = append(out, s+len(ins))
	}
	m.cursors = slices.Compact(out)
}

func TestRandomPointCursorsAgainstModel(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	b := New("abc", "", "defg", "h")
	m := &model{text: b.Text(), cursors: []int{0}}
	toOffset := func(p Position) int {
		off := 0
		for i := 0; i < p.Line; i++ {
			off += len(b.Line(i)) + 1
		}
		return off + p.Col
	}
	inserts := []string{"x", "yz", "\n", "a\nb", " "}
	for step := 0; step < 4000; step++ {
		switch rng.Intn(6) {
		case 0, 1:
			s := inserts[rng.Intn(len(inserts))]
			b.InsertString(s)
			m.edit(0, s)
		case 2:
			b.Delete()
			m.edit(-1, "")
		case 3:
			b.DeleteForward()
			m.edit(1, "")
		case 4:
			l, c := rng.Intn(6), rng.Intn(6)
			b.AddCursor(l, c)
			m.cursors = append(m.cursors, toOffset(b.Clamp(l, c)))
			slices.Sort(m.cursors)
			m.cursors = slices.Compact(m.cursors)
		case 5:
			if rng.Intn(4) == 0 {
				b.ClearCursors()
				p := toOffset(b.Cursor(0).Head)
				m.cursors = []int{p}
			}
		}
		if b.Text() != m.text {
			t.Fatalf("step %d: text %q want %q", step, b.Text(), m.text)
		}
		var got []int
		for _, c := range b.Cursors() {
			got = append(got, toOffset(c.Head))
		}
		if !slices.Equal(got, m.cursors) {
			t.Fatalf("step %d: cursors %v want %v", step, got, m.cursors)
		}
	}
}

func TestUndoEverythingRestoresInitialDocument(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	b := New("one", "two", "three", "four")
	start := b.Text()
	for i := 0; i < 500; i++ {
		switch rng.Intn(5) {
		case 0:
			b.AddCursor(rng.Intn(5), rng.Intn(6))
		case 1:
			b.Move(Direction(rng.Intn(6)), rng.Intn(2) == 0)
		case 2:
			b.InsertString([]string{"q", "\n", "rs\nt"}[rng.Intn(3)])
		case 3:
			b.Delete()
		case 4:
			b.DeleteForward()
		}
	}
	final := b.Text()
	for b.Undo() {
	}
	if b.Text() != start {
		t.Fatalf("after undo-all: %q want %q", b.Text(), start)
	}
	for b.Redo() {
	}
	if b.Text() != final {
		t.Fatalf("after redo-all text differs")
	}
}

func TestDirection(t *testing.T) {
	for i := Left; i <= End; i++ {
		d, ok := ParseDirection(i.String())
		if !ok || d != i {
			t.Errorf("round trip of %v failed", i)
		}
	}
	if _, ok := ParseDirection("sideways"); ok {
		t.Error("accepted bad direction")
	}
	if Direction(99).String() != "invalid" {
		t.Error("String of invalid direction")
	}
}

func ExampleBuffer() {
	b := New("hello world")
	b.Move(End, false)
	b.InsertString("!")
	b.Goto(0, 5)
	b.InsertString(",")
	fmt.Println(b.Text())
	b.Undo()
	fmt.Println(b.Text())
	// Output:
	// hello, world!
	// hello world!
}
