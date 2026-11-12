package textbuffer

import "fmt"

// Direction says how Move moves each cursor's head.
type Direction int

// The supported movements.
const (
	Left Direction = iota
	Right
	Up
	Down
	Home
	End
)

var directionNames = [...]string{"left", "right", "up", "down", "home", "end"}

// String returns the lower-case name of the direction ("left", "right", ...).
func (d Direction) String() string {
	if d < 0 || int(d) >= len(directionNames) {
		return fmt.Sprintf("Direction(%d)", int(d))
	}
	return directionNames[d]
}

// ParseDirection converts a name such as "left" or "home" to a Direction.
func ParseDirection(name string) (Direction, error) {
	for i, n := range directionNames {
		if n == name {
			return Direction(i), nil
		}
	}
	return 0, fmt.Errorf("textbuffer: unknown direction %q", name)
}

// Move moves every cursor in direction dir.
//
// Without extend, a cursor holding a selection collapses to the start of its
// range for Left or to its end for Right, and stops there; for the other
// directions the selection is dropped and the head then moves. With extend, a
// cursor without a selection first anchors at its head, then the head moves
// and the anchor stays; if the head ends up on the anchor the selection
// disappears.
//
// Up and Down use each cursor's goal column. They keep it, except that moving
// up from the first line goes to (0, 0) with goal column 0, and moving down
// from the last line goes to the end of the document with that column as the
// goal. After any other direction the goal becomes the head's column. Cursors
// that collide are merged. The history is not touched.
func (b *Buffer) Move(dir Direction, extend bool) {
	for i := range b.cursors {
		b.moveCursor(&b.cursors[i], dir, extend)
	}
	if dir == Up || dir == Down {
		b.cursors = normalize(b.cursors)
		return
	}
	b.finishCommand()
}

func (b *Buffer) moveCursor(c *Cursor, dir Direction, extend bool) {
	if !extend && c.Selected {
		switch dir {
		case Left:
			c.Head, c.Selected = c.Start(), false
			return
		case Right:
			c.Head, c.Selected = c.End(), false
			return
		}
		c.Selected = false
	}
	if extend && !c.Selected {
		c.Anchor, c.Selected = c.Head, true
	}

	d := b.doc
	h := c.Head
	switch dir {
	case Left:
		if h.Line > 0 || h.Col > 0 {
			h = d.prev(h)
		}
	case Right:
		if h != d.end() {
			h = d.next(h)
		}
	case Home:
		h.Col = 0
	case End:
		h.Col = d.lineLen(h.Line)
	case Up:
		if h.Line == 0 {
			h = Position{}
			c.Goal = 0
		} else {
			h = Position{h.Line - 1, min(c.Goal, d.lineLen(h.Line-1))}
		}
	case Down:
		if last := len(d.lines) - 1; h.Line == last {
			h = d.end()
			c.Goal = h.Col
		} else {
			h = Position{h.Line + 1, min(c.Goal, d.lineLen(h.Line+1))}
		}
	}
	c.Head = h
	if c.Selected && c.Head == c.Anchor {
		c.Selected = false
	}
}
