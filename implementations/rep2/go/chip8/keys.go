package chip8

// KeyEvent sets the 16-bit key state from the given cycle onwards. Bit k of
// Mask set means key k is held down.
type KeyEvent struct {
	Cycle uint64
	Mask  uint16
}

// KeySchedule is a list of key events in strictly increasing cycle order.
type KeySchedule []KeyEvent
