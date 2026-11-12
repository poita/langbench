package spreadsheet

import (
	"fmt"
	"slices"
	"strconv"
)

type contentKind uint8

const (
	contentEmpty contentKind = iota
	contentNumber
	contentString
	contentFormula
)

// cell is one node of the dependency graph.
type cell struct {
	key     cellKey
	content contentKind
	num     float64  // contentNumber
	str     string   // contentString
	formula *formula // contentFormula

	value Value // current value; always up to date between commands

	deps    []*cell            // cells this cell's formula reads (distinct)
	rev     map[*cell]struct{} // cells whose formulas read this cell
	selfRef bool               // formula reads the cell itself

	// Scratch state for recalculation.
	mark    uint32 // == Sheet.epoch when the cell is in the affected set
	index   int32  // Tarjan index (0 = unvisited)
	low     int32
	onStack bool
}

// Sheet is an in-memory spreadsheet. The zero value is not usable; call New.
type Sheet struct {
	cells map[cellKey]*cell
	epoch uint32
}

// Entry is a non-empty cell as reported by Dump.
type Entry struct {
	Name  string // cell name, e.g. "B12"
	Value Value
}

// New returns an empty sheet.
func New() *Sheet {
	return &Sheet{cells: make(map[cellKey]*cell)}
}

// get returns the cell for key, creating an empty one if needed.
func (s *Sheet) get(key cellKey) *cell {
	c := s.cells[key]
	if c == nil {
		c = &cell{key: key}
		s.cells[key] = c
	}
	return c
}

func (s *Sheet) lookupName(name string) (*cell, error) {
	key, ok := parseCellName(name)
	if !ok {
		return nil, fmt.Errorf("spreadsheet: invalid cell name %q", name)
	}
	return s.get(key), nil
}

// Set replaces the content of the named cell. content is interpreted as in
// the command language: text starting with '=' is a formula, text enclosed in
// double quotes is a string, and anything else must be a decimal number such
// as 5, -3 or 4.50. On error the sheet is left unchanged.
func (s *Sheet) Set(name, content string) error {
	switch {
	case len(content) > 0 && content[0] == '=':
		return s.SetFormula(name, content[1:])
	case len(content) >= 2 && content[0] == '"' && content[len(content)-1] == '"':
		return s.SetString(name, content[1:len(content)-1])
	}
	if !isNumberLiteral(content) {
		return fmt.Errorf("spreadsheet: invalid content %q", content)
	}
	f, err := strconv.ParseFloat(content, 64)
	if err != nil {
		return fmt.Errorf("spreadsheet: invalid number %q: %w", content, err)
	}
	return s.SetNumber(name, f)
}

// isNumberLiteral reports whether s matches -?[0-9]+(\.[0-9]+)?.
func isNumberLiteral(s string) bool {
	i := 0
	if i < len(s) && s[i] == '-' {
		i++
	}
	digits := func() bool {
		start := i
		for i < len(s) && isDigit(s[i]) {
			i++
		}
		return i > start
	}
	if !digits() {
		return false
	}
	if i < len(s) && s[i] == '.' {
		i++
		if !digits() {
			return false
		}
	}
	return i == len(s)
}

// SetNumber stores a number in the named cell. NaN and infinities are
// rejected.
func (s *Sheet) SetNumber(name string, f float64) error {
	c, err := s.lookupName(name)
	if err != nil {
		return err
	}
	if f != f || f > maxFloat || f < -maxFloat {
		return fmt.Errorf("spreadsheet: number %v is not finite", f)
	}
	if f == 0 {
		f = 0 // normalise -0
	}
	s.install(c, contentNumber, f, "", nil)
	return nil
}

const maxFloat = 1.7976931348623157e308

// SetString stores a string in the named cell.
func (s *Sheet) SetString(name, text string) error {
	c, err := s.lookupName(name)
	if err != nil {
		return err
	}
	s.install(c, contentString, 0, text, nil)
	return nil
}

// SetFormula stores a formula in the named cell. src is the formula text
// without the leading '='. A syntax error leaves the sheet unchanged. A
// formula containing an invalid reference is accepted and evaluates to #REF!.
func (s *Sheet) SetFormula(name, src string) error {
	c, err := s.lookupName(name)
	if err != nil {
		return err
	}
	f, err := parseFormula(src, s.get)
	if err != nil {
		return fmt.Errorf("spreadsheet: formula in %s: %w", name, err)
	}
	s.install(c, contentFormula, 0, "", f)
	return nil
}

// Clear empties the named cell.
func (s *Sheet) Clear(name string) error {
	c, err := s.lookupName(name)
	if err != nil {
		return err
	}
	s.install(c, contentEmpty, 0, "", nil)
	return nil
}

// Get returns the current value of the named cell; an empty cell yields the
// zero (empty) Value.
func (s *Sheet) Get(name string) (Value, error) {
	key, ok := parseCellName(name)
	if !ok {
		return Value{}, fmt.Errorf("spreadsheet: invalid cell name %q", name)
	}
	if c := s.cells[key]; c != nil {
		return c.value, nil
	}
	return Value{}, nil
}

// Dump returns every non-empty cell in row-major order.
func (s *Sheet) Dump() []Entry {
	var cells []*cell
	for _, c := range s.cells {
		if c.content != contentEmpty {
			cells = append(cells, c)
		}
	}
	slices.SortFunc(cells, func(a, b *cell) int { return int(a.key) - int(b.key) })
	out := make([]Entry, len(cells))
	for i, c := range cells {
		out[i] = Entry{Name: c.key.String(), Value: c.value}
	}
	return out
}

// install replaces c's content, rewires its dependency edges and recalculates
// everything affected.
func (s *Sheet) install(c *cell, kind contentKind, num float64, str string, f *formula) {
	for _, d := range c.deps {
		delete(d.rev, c)
	}
	c.deps, c.selfRef, c.formula = nil, false, nil
	c.content, c.num, c.str = kind, num, str
	if f != nil {
		c.formula = f
		c.deps = f.deps
		for _, d := range f.deps {
			if d.rev == nil {
				d.rev = make(map[*cell]struct{})
			}
			d.rev[c] = struct{}{}
			if d == c {
				c.selfRef = true
			}
		}
	}
	s.recalc(c)
}

// recalc re-evaluates the affected set of start: start plus every cell that
// transitively reads it. Tarjan's algorithm over the subgraph induced by the
// affected set emits strongly connected components dependencies-first, so each
// non-cyclic cell is evaluated after everything it reads. The traversal is
// iterative because dependency chains can be very deep.
func (s *Sheet) recalc(start *cell) {
	s.epoch++
	epoch := s.epoch
	affected := []*cell{start}
	start.mark = epoch
	for i := 0; i < len(affected); i++ {
		for r := range affected[i].rev {
			if r.mark != epoch {
				r.mark = epoch
				affected = append(affected, r)
			}
		}
	}
	for _, c := range affected {
		c.index, c.low, c.onStack = 0, 0, false
	}

	type frame struct {
		c *cell
		i int
	}
	var (
		counter int32
		stack   []*cell
		calls   []frame
	)
	push := func(c *cell) {
		counter++
		c.index, c.low, c.onStack = counter, counter, true
		stack = append(stack, c)
		calls = append(calls, frame{c: c})
	}
	for _, root := range affected {
		if root.index != 0 {
			continue
		}
		push(root)
		for len(calls) > 0 {
			f := &calls[len(calls)-1]
			c := f.c
			if f.i < len(c.deps) {
				d := c.deps[f.i]
				f.i++
				if d.mark != epoch {
					continue
				}
				if d.index == 0 {
					push(d)
				} else if d.onStack && d.index < c.low {
					c.low = d.index
				}
				continue
			}
			calls = calls[:len(calls)-1]
			if c.low == c.index {
				top := len(stack) - 1
				for stack[top] != c {
					top--
				}
				comp := stack[top:]
				stack = stack[:top]
				for _, m := range comp {
					m.onStack = false
				}
				if len(comp) > 1 || c.selfRef {
					for _, m := range comp {
						m.value = Error(ErrCycle)
					}
				} else {
					c.value = c.evaluate()
				}
			}
			if len(calls) > 0 {
				p := calls[len(calls)-1].c
				if c.low < p.low {
					p.low = c.low
				}
			}
		}
	}
}

// evaluate computes the cell's value from its content and the stored values of
// the cells it reads.
func (c *cell) evaluate() Value {
	switch c.content {
	case contentNumber:
		return Number(c.num)
	case contentString:
		return String(c.str)
	case contentFormula:
		if c.formula.badRef {
			return Error(ErrRef)
		}
		v := c.formula.root.eval()
		if v.kind == KindEmpty {
			return Number(0)
		}
		return v
	}
	return Value{}
}
