package textbuffer

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
)

// modelCursor is a cursor in the offset view of the naive reference model.
type modelCursor struct {
	head, anchor int // offsets; anchor == head means no selection
	primary      bool
	goal         int
}

func (c modelCursor) start() int { return min(c.head, c.anchor) }
func (c modelCursor) end() int   { return max(c.head, c.anchor) }
func (c modelCursor) sel() bool  { return c.head != c.anchor }

type modelEdit struct {
	before, after    []modelCursor
	text, undoneText string
	reps             []modelRep
}

type modelRep struct {
	off      int
	removed  string
	inserted string
}

// model is a deliberately naive implementation of the specification: the
// document is one string and every replacement shifts all later cursors.
type model struct {
	text    string
	cursors []modelCursor
	undo    []modelEdit
	redo    []modelEdit
}

func newModel(text string) *model {
	return &model{text: text, cursors: []modelCursor{{primary: true}}}
}

func (m *model) lines() []string { return strings.Split(m.text, "\n") }

func (m *model) offset(p Position) int {
	off := 0
	ls := m.lines()
	for i := 0; i < p.Line; i++ {
		off += len(ls[i]) + 1
	}
	return off + p.Col
}

func (m *model) position(off int) Position {
	line := strings.Count(m.text[:off], "\n")
	return Position{line, off - (strings.LastIndexByte(m.text[:off], '\n') + 1)}
}

func (m *model) clamp(line, col int) int {
	ls := m.lines()
	line = min(max(line, 0), len(ls)-1)
	col = min(max(col, 0), len(ls[line]))
	return m.offset(Position{line, col})
}

func (m *model) normalize() {
	cs := m.cursors
	sort.SliceStable(cs, func(i, j int) bool {
		if cs[i].start() != cs[j].start() {
			return cs[i].start() < cs[j].start()
		}
		return cs[i].end() > cs[j].end()
	})
	var out []modelCursor
	cur := cs[0]
	for _, c := range cs[1:] {
		var join bool
		if cur.sel() && c.sel() {
			join = c.start() < cur.end()
		} else {
			join = c.start() <= cur.end()
		}
		if !join {
			out = append(out, cur)
			cur = c
			continue
		}
		s, e := cur.start(), max(cur.end(), c.end())
		backward := cur.sel() && cur.head == cur.start()
		n := modelCursor{primary: cur.primary || c.primary, goal: cur.goal}
		switch {
		case s == e:
			n.head, n.anchor = s, s
		case backward:
			n.head, n.anchor = s, e
		default:
			n.head, n.anchor = e, s
		}
		cur = n
	}
	m.cursors = append(out, cur)
}

func (m *model) resetGoals() {
	for i := range m.cursors {
		m.cursors[i].goal = m.position(m.cursors[i].head).Col
	}
}

func (m *model) finish() { m.normalize(); m.resetGoals() }

func (m *model) replace(s, e int, ins string) {
	m.text = m.text[:s] + ins + m.text[e:]
}

func (m *model) edit(kind editKind, ins string) {
	before := append([]modelCursor(nil), m.cursors...)
	var reps []modelRep
	for i := range m.cursors {
		c := m.cursors[i]
		s, e := c.start(), c.end()
		text := ""
		switch {
		case kind == editInsert:
			text = ins
		case c.sel():
		case kind == editBackspace:
			if s > 0 {
				s--
			}
		default:
			if e < len(m.text) {
				e++
			}
		}
		if s == e && text == "" {
			m.cursors[i].anchor = m.cursors[i].head
			continue
		}
		reps = append(reps, modelRep{s, m.text[s:e], text})
		m.replace(s, e, text)
		nh := s + len(text)
		m.cursors[i].head, m.cursors[i].anchor = nh, nh
		for j := i + 1; j < len(m.cursors); j++ {
			for _, p := range []*int{&m.cursors[j].head, &m.cursors[j].anchor} {
				*p = *p - e + s + len(text)
			}
		}
	}
	m.finish()
	if len(reps) > 0 {
		m.undo = append(m.undo, modelEdit{before: before, after: append([]modelCursor(nil), m.cursors...), reps: reps})
		m.redo = nil
	}
}

func (m *model) move(dir Direction, extend bool) {
	ls := m.lines()
	for i := range m.cursors {
		c := &m.cursors[i]
		if !extend && c.sel() {
			switch dir {
			case Left:
				c.head, c.anchor = c.start(), c.start()
				continue
			case Right:
				c.head, c.anchor = c.end(), c.end()
				continue
			}
			c.anchor = c.head
		}
		if !extend {
			c.anchor = c.head
		}
		p := m.position(c.head) // with extend, anchor keeps the old head
		switch dir {
		case Left:
			if c.head > 0 {
				c.head--
			}
		case Right:
			if c.head < len(m.text) {
				c.head++
			}
		case Home:
			c.head -= p.Col
		case End:
			c.head += len(ls[p.Line]) - p.Col
		case Up:
			if p.Line == 0 {
				c.head, c.goal = 0, 0
			} else {
				c.head = m.offset(Position{p.Line - 1, min(c.goal, len(ls[p.Line-1]))})
			}
		case Down:
			if p.Line == len(ls)-1 {
				c.head = len(m.text)
				c.goal = len(ls[p.Line])
			} else {
				c.head = m.offset(Position{p.Line + 1, min(c.goal, len(ls[p.Line+1]))})
			}
		}
		if !extend {
			c.anchor = c.head
		}
	}
	m.normalize()
	if dir != Up && dir != Down {
		m.resetGoals()
	}
}

func (m *model) undoCmd() {
	if len(m.undo) == 0 {
		m.resetGoals()
		return
	}
	e := m.undo[len(m.undo)-1]
	m.undo = m.undo[:len(m.undo)-1]
	// Replacements were recorded as offsets in the document before each one.
	for i := len(e.reps) - 1; i >= 0; i-- {
		r := e.reps[i]
		m.replace(r.off, r.off+len(r.inserted), r.removed)
	}
	m.cursors = append([]modelCursor(nil), e.before...)
	m.resetGoals()
	m.redo = append(m.redo, e)
}

func (m *model) redoCmd() {
	if len(m.redo) == 0 {
		m.resetGoals()
		return
	}
	e := m.redo[len(m.redo)-1]
	m.redo = m.redo[:len(m.redo)-1]
	for _, r := range e.reps {
		m.replace(r.off, r.off+len(r.removed), r.inserted)
	}
	m.cursors = append([]modelCursor(nil), e.after...)
	m.resetGoals()
	m.undo = append(m.undo, e)
}

// compare checks that the buffer and the model agree.
func (m *model) compare(t *testing.T, b *Buffer, step string) {
	t.Helper()
	if got := b.Text(); got != m.text {
		t.Fatalf("%s: text mismatch\n got %q\nwant %q", step, got, m.text)
	}
	got := b.Cursors()
	if len(got) != len(m.cursors) {
		t.Fatalf("%s: %d cursors, want %d (%+v vs %+v)", step, len(got), len(m.cursors), got, m.cursors)
	}
	for i, c := range got {
		w := m.cursors[i]
		if c.Head != m.position(w.head) || c.Primary != w.primary || c.Selected != w.sel() ||
			(c.Selected && c.Anchor != m.position(w.anchor)) || c.Goal != w.goal {
			t.Fatalf("%s: cursor %d = %+v, want head %v anchor %v primary %v goal %d",
				step, i, c, m.position(w.head), m.position(w.anchor), w.primary, w.goal)
		}
	}
}

func TestBufferAgainstModel(t *testing.T) {
	dirs := []Direction{Left, Right, Up, Down, Home, End}
	for seed := int64(0); seed < 300; seed++ {
		rng := rand.New(rand.NewSource(seed))
		nlines := rng.Intn(6)
		lines := make([]string, nlines)
		for i := range lines {
			lines[i] = randText(rng, rng.Intn(8), false)
		}
		b := NewFromLines(lines)
		m := newModel(strings.Join(append([]string(nil), lines...), "\n"))
		if nlines == 0 {
			m.text = ""
		}
		for step := 0; step < 200; step++ {
			var desc string
			switch r := rng.Intn(100); {
			case r < 20:
				txt := randText(rng, 1+rng.Intn(4), true)
				desc = "insert " + txt
				b.Insert(txt)
				m.edit(editInsert, txt)
			case r < 28:
				desc = "delete"
				b.Delete()
				m.edit(editBackspace, "")
			case r < 36:
				desc = "delete-forward"
				b.DeleteForward()
				m.edit(editDeleteForward, "")
			case r < 60:
				d, ext := dirs[rng.Intn(len(dirs))], rng.Intn(2) == 0
				desc = "move " + d.String()
				b.Move(d, ext)
				m.move(d, ext)
			case r < 68:
				l, c := rng.Intn(8)-1, rng.Intn(10)-1
				desc = "goto"
				b.GoTo(l, c)
				m.cursors = []modelCursor{{head: m.clamp(l, c), anchor: m.clamp(l, c), primary: true}}
				m.cursors[0].anchor = m.cursors[0].head
				m.resetGoals()
			case r < 82:
				l, c := rng.Intn(8)-1, rng.Intn(10)-1
				desc = "add-cursor"
				b.AddCursor(l, c)
				o := m.clamp(l, c)
				m.cursors = append(m.cursors, modelCursor{head: o, anchor: o})
				m.finish()
			case r < 85:
				desc = "clear-cursors"
				b.ClearCursors()
				for _, c := range m.cursors {
					if c.primary {
						m.cursors = []modelCursor{c}
						break
					}
				}
				m.finish()
			case r < 93:
				desc = "undo"
				b.Undo()
				m.undoCmd()
			default:
				desc = "redo"
				b.Redo()
				m.redoCmd()
			}
			m.compare(t, b, fmt.Sprintf("seed %d step %d (%s)", seed, step, desc))
		}
	}
}

func randText(rng *rand.Rand, n int, newlines bool) string {
	const alphabet = "abc d"
	var sb strings.Builder
	for i := 0; i < n; i++ {
		if newlines && rng.Intn(4) == 0 {
			sb.WriteByte('\n')
		} else {
			sb.WriteByte(alphabet[rng.Intn(len(alphabet))])
		}
	}
	return sb.String()
}
