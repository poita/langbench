package chip8

// KeyEvent sets the 16-bit keypad state (bit k set means key k is held) from
// the start of the given cycle onwards.
type KeyEvent struct {
	Cycle uint64
	Mask  uint16
}

// KeySchedule is a list of key events in strictly increasing cycle order.
type KeySchedule []KeyEvent

// Valid reports whether the events are in strictly increasing cycle order.
func (s KeySchedule) Valid() bool {
	for i := 1; i < len(s); i++ {
		if s[i].Cycle <= s[i-1].Cycle {
			return false
		}
	}
	return true
}
