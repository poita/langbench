package textbuffer

// Direction is a cursor movement.
type Direction int

// The cursor movements understood by [Buffer.Move].
const (
	Left Direction = iota
	Right
	Up
	Down
	Home
	End
)

var directionNames = [...]string{"left", "right", "up", "down", "home", "end"}

// String returns the lower-case name of the direction.
func (d Direction) String() string {
	if d < 0 || int(d) >= len(directionNames) {
		return "invalid"
	}
	return directionNames[d]
}

// ParseDirection converts "left", "right", "up", "down", "home" or "end".
func ParseDirection(s string) (Direction, bool) {
	for i, n := range directionNames {
		if n == s {
			return Direction(i), true
		}
	}
	return 0, false
}

// Move moves every cursor. Without extend, a selection collapses (to its
// start for Left, its end for Right; other directions drop it and then
// move). With extend, a cursor keeps or starts a selection and only the head
// moves. Up and Down use and preserve each cursor's goal column; every other
// movement resets it to the head's column.
func (b *Buffer) Move(dir Direction, extend bool) {
	for i := range b.cursors {
		c := &b.cursors[i]
		if !extend && c.HasSelection && (dir == Left || dir == Right) {
			if dir == Left {
				c.Head = c.Start()
			} else {
				c.Head = c.End()
			}
			c.HasSelection = false
			continue
		}
		if extend {
			if !c.HasSelection {
				c.Anchor = c.Head
			}
		} else {
			c.HasSelection = false
		}
		b.moveHead(c, dir)
		if extend {
			c.HasSelection = c.Head != c.Anchor
		}
	}
	b.cursors = normalize(b.cursors)
	if dir != Up && dir != Down {
		b.resetGoals()
	}
}

func (b *Buffer) moveHead(c *Cursor, dir Direction) {
	h := c.Head
	switch dir {
	case Left:
		if h.Col > 0 {
			h.Col--
		} else if h.Line > 0 {
			h.Line--
			h.Col = len(b.doc.line(h.Line))
		}
	case Right:
		if h.Col < len(b.doc.line(h.Line)) {
			h.Col++
		} else if h.Line < b.LineCount()-1 {
			h.Line++
			h.Col = 0
		}
	case Home:
		h.Col = 0
	case End:
		h.Col = len(b.doc.line(h.Line))
	case Up:
		if h.Line == 0 {
			h.Col = 0
			c.Goal = 0
		} else {
			h.Line--
			h.Col = min(c.Goal, len(b.doc.line(h.Line)))
		}
	case Down:
		if h.Line == b.LineCount()-1 {
			h.Col = len(b.doc.line(h.Line))
			c.Goal = h.Col
		} else {
			h.Line++
			h.Col = min(c.Goal, len(b.doc.line(h.Line)))
		}
	}
	c.Head = h
}
