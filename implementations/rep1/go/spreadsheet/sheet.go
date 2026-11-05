package spreadsheet

import (
	"slices"

	"example.com/spreadsheet/cellref"
	"example.com/spreadsheet/formula"
)

// cell is the per-cell record. Cells are addressed by dense int32 handles
// into Sheet.cells; a handle is allocated the first time a cell is named
// (by a command or by a formula) and never reused.
type cell struct {
	key     int32 // cellref key
	content contentKind
	val     Value
	expr    *formula.Expr
	selfDep bool    // the formula refers to this very cell
	deps    []int32 // deduplicated cells this formula reads
	rdeps   []int32 // cells whose formulas read this cell

	// Scratch state for recalculation; valid only when mark == Sheet.gen.
	mark  uint32
	tIdx  int32
	tLow  int32
	tPos  int32
	onStk bool
	// depStamp is used to deduplicate dependency lists.
	depStamp uint32
}

// Sheet is a spreadsheet. The zero value is not usable; call New. A Sheet is
// not safe for concurrent use.
type Sheet struct {
	cells  []cell
	handle map[int32]int32 // cell key -> handle

	nonEmpty int     // number of non-empty cells
	order    []int32 // cached row-major order of non-empty cells
	orderOK  bool

	gen      uint32
	depGen   uint32
	affected []int32 // scratch: affected set A
	work     []int32 // scratch: DFS / Tarjan call stack
	stk      []int32 // scratch: Tarjan stack
	scc      []int32 // scratch: current component
	depBuf   []int32 // scratch: raw dependency list
	scratch  []byte  // scratch: text building in '&'
}

// New returns an empty sheet.
func New() *Sheet {
	return &Sheet{handle: make(map[int32]int32)}
}

// Entry is a non-empty cell as reported by Dump.
type Entry struct {
	Name  string
	Value Value
}

// handleFor returns the handle of the cell with the given key, creating the
// cell if needed.
func (s *Sheet) handleFor(key int32) int32 {
	if h, ok := s.handle[key]; ok {
		return h
	}
	h := int32(len(s.cells))
	s.cells = append(s.cells, cell{key: key})
	s.handle[key] = h
	return h
}

// Set replaces the content of the named cell and recalculates every cell
// that depends on it. content is a number literal (-?[0-9]+(\.[0-9]+)?), a
// string literal ("...", with no embedded quotes) or a formula (=...). If
// the name or content is invalid, an error is returned and the sheet is not
// modified.
func (s *Sheet) Set(name, content string) error {
	key, ok := cellref.ParseKey(name)
	if !ok {
		return ErrCellName
	}
	pc, err := parseContent(content)
	if err != nil {
		return err
	}
	h := s.handleFor(int32(key))
	s.unlink(h)
	s.install(h, pc)
	s.recalc(h)
	return nil
}

// Clear makes the named cell empty and recalculates its dependents.
func (s *Sheet) Clear(name string) error {
	key, ok := cellref.ParseKey(name)
	if !ok {
		return ErrCellName
	}
	h, exists := s.handle[int32(key)]
	if !exists {
		return nil // never set or referenced: already empty
	}
	if s.cells[h].content == contentEmpty {
		return nil
	}
	s.unlink(h)
	s.install(h, parsedContent{})
	s.recalc(h)
	return nil
}

// Get returns the value of the named cell. An empty cell yields the zero
// (Empty) Value.
func (s *Sheet) Get(name string) (Value, error) {
	key, ok := cellref.ParseKey(name)
	if !ok {
		return Value{}, ErrCellName
	}
	if h, exists := s.handle[int32(key)]; exists {
		return s.cells[h].val, nil
	}
	return Value{}, nil
}

// Dump returns every non-empty cell in row-major order (ascending row, then
// ascending column).
func (s *Sheet) Dump() []Entry {
	order := s.sortedCells()
	out := make([]Entry, len(order))
	for i, h := range order {
		c := &s.cells[h]
		col, row := cellref.Split(int(c.key))
		out[i] = Entry{Name: cellref.Name(col, row), Value: c.val}
	}
	return out
}

// AppendDump appends the dump as lines of "<CELL> <value>\n" to dst. It is
// equivalent to, but cheaper than, formatting the result of Dump.
func (s *Sheet) AppendDump(dst []byte) []byte {
	for _, h := range s.sortedCells() {
		c := &s.cells[h]
		col, row := cellref.Split(int(c.key))
		dst = cellref.Append(dst, col, row)
		dst = append(dst, ' ')
		dst = c.val.AppendTo(dst)
		dst = append(dst, '\n')
	}
	return dst
}

// sortedCells returns the handles of the non-empty cells in row-major order,
// caching the result until the set of non-empty cells changes.
func (s *Sheet) sortedCells() []int32 {
	if s.orderOK {
		return s.order
	}
	s.order = s.order[:0]
	for h := range s.cells {
		if s.cells[h].content != contentEmpty {
			s.order = append(s.order, int32(h))
		}
	}
	slices.SortFunc(s.order, func(a, b int32) int {
		return int(s.cells[a].key) - int(s.cells[b].key)
	})
	s.orderOK = true
	return s.order
}

// unlink removes cell h from the dependents lists of its current
// dependencies and forgets its formula.
func (s *Sheet) unlink(h int32) {
	c := &s.cells[h]
	for _, d := range c.deps {
		rd := s.cells[d].rdeps
		for i, x := range rd {
			if x == h {
				last := len(rd) - 1
				rd[i] = rd[last]
				s.cells[d].rdeps = rd[:last]
				break
			}
		}
	}
	c.deps = c.deps[:0]
	c.expr = nil
	c.selfDep = false
}

// install stores new content in cell h and links its dependencies. For a
// literal the value is set immediately; for a formula the value is computed
// by recalc.
func (s *Sheet) install(h int32, pc parsedContent) {
	if (s.cells[h].content == contentEmpty) != (pc.kind == contentEmpty) {
		s.orderOK = false
		if pc.kind == contentEmpty {
			s.nonEmpty--
		} else {
			s.nonEmpty++
		}
	}
	switch pc.kind {
	case contentEmpty:
		c := &s.cells[h]
		c.content, c.val = contentEmpty, Value{}
	case contentLiteral:
		c := &s.cells[h]
		c.content, c.val = contentLiteral, pc.value
	case contentFormula:
		pc.expr.Resolve(s.handleFor) // may grow s.cells
		s.depGen++
		raw := pc.expr.Deps(s.depBuf[:0])
		s.depBuf = raw
		c := &s.cells[h]
		c.content, c.expr = contentFormula, pc.expr
		c.deps = c.deps[:0]
		for _, d := range raw {
			dc := &s.cells[d]
			if dc.depStamp == s.depGen {
				continue
			}
			dc.depStamp = s.depGen
			c.deps = append(c.deps, d)
			dc.rdeps = append(dc.rdeps, h)
			if d == h {
				c.selfDep = true
			}
		}
	}
}
