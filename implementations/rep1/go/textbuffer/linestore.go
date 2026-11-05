package textbuffer

// lineStore is a gap buffer of lines. Line i lives in slot i when
// i < gapStart and in slot i+gapLen otherwise. Replacing a run of lines moves
// the gap to the run first, so a sequence of edits at ascending (or
// descending) line numbers moves each slot O(1) times in total.
type lineStore struct {
	slots    [][]byte
	gapStart int
	gapLen   int
}

func newLineStore(lines [][]byte) lineStore {
	return lineStore{slots: lines, gapStart: len(lines)}
}

// count returns the number of lines.
func (s *lineStore) count() int { return len(s.slots) - s.gapLen }

// at returns line i.
func (s *lineStore) at(i int) []byte {
	if i >= s.gapStart {
		i += s.gapLen
	}
	return s.slots[i]
}

// set replaces the buffer of line i without changing the line count.
func (s *lineStore) set(i int, b []byte) {
	if i >= s.gapStart {
		i += s.gapLen
	}
	s.slots[i] = b
}

// moveGap makes the gap start at line index to.
func (s *lineStore) moveGap(to int) {
	switch {
	case to < s.gapStart:
		copy(s.slots[to+s.gapLen:s.gapStart+s.gapLen], s.slots[to:s.gapStart])
	case to > s.gapStart:
		copy(s.slots[s.gapStart:to], s.slots[s.gapStart+s.gapLen:to+s.gapLen])
	}
	s.gapStart = to
}

// grow makes the gap at least need slots wide, growing geometrically.
func (s *lineStore) grow(need int) {
	tail := len(s.slots) - s.gapStart - s.gapLen
	newLen := max(2*len(s.slots), len(s.slots)-s.gapLen+need+16)
	slots := make([][]byte, newLen)
	copy(slots, s.slots[:s.gapStart])
	newGap := newLen - s.gapStart - tail
	copy(slots[s.gapStart+newGap:], s.slots[s.gapStart+s.gapLen:])
	s.slots = slots
	s.gapLen = newGap
}

// replace substitutes the k lines starting at index a by repl.
func (s *lineStore) replace(a, k int, repl [][]byte) {
	s.moveGap(a)
	base := s.gapStart + s.gapLen
	clear(s.slots[base : base+k])
	s.gapLen += k
	if len(repl) > s.gapLen {
		s.grow(len(repl))
	}
	copy(s.slots[s.gapStart:], repl)
	s.gapStart += len(repl)
	s.gapLen -= len(repl)
}
