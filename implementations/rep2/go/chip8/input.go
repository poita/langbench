package chip8

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// KeyEvent sets the 16-bit key state Mask immediately before the cycle
// numbered Cycle executes.
type KeyEvent struct {
	Cycle uint64
	Mask  uint16
}

// Program is a parsed input: a ROM, a cycle budget and a key schedule.
type Program struct {
	ROM      []byte
	Cycles   uint64
	Schedule []KeyEvent
}

// ParseInput parses the textual input format: a hex ROM line, a decimal cycle
// count line and an optional key-schedule line of "<cycle>:<mask>" events.
func ParseInput(data []byte) (*Program, error) {
	text := strings.TrimRight(string(data), "\r\n")
	lines := strings.Split(text, "\n")
	if len(lines) < 2 {
		return nil, errors.New("chip8: input needs a ROM line and a cycle line")
	}
	rom, err := ParseHexROM(lines[0])
	if err != nil {
		return nil, err
	}
	cycles, err := strconv.ParseUint(strings.TrimSpace(lines[1]), 10, 64)
	if err != nil {
		return nil, fmt.Errorf("chip8: bad cycle count: %w", err)
	}
	p := &Program{ROM: rom, Cycles: cycles}
	if len(lines) > 2 {
		p.Schedule, err = ParseSchedule(lines[2])
		if err != nil {
			return nil, err
		}
	}
	return p, nil
}

// ParseHexROM decodes a string of hexadecimal digit pairs into bytes.
func ParseHexROM(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if len(s) == 0 || len(s)%2 != 0 {
		return nil, errors.New("chip8: ROM must be a non-empty even number of hex digits")
	}
	if len(s)/2 > MaxROMSize {
		return nil, fmt.Errorf("chip8: ROM larger than %d bytes", MaxROMSize)
	}
	rom := make([]byte, len(s)/2)
	for i := range rom {
		hi, ok1 := hexVal(s[2*i])
		lo, ok2 := hexVal(s[2*i+1])
		if !ok1 || !ok2 {
			return nil, fmt.Errorf("chip8: invalid hex digit near offset %d", 2*i)
		}
		rom[i] = hi<<4 | lo
	}
	return rom, nil
}

func hexVal(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// ParseSchedule parses a space-separated list of "<cycle>:<mask>" events.
// An empty string yields an empty schedule.
func ParseSchedule(s string) ([]KeyEvent, error) {
	fields := strings.Fields(s)
	events := make([]KeyEvent, 0, len(fields))
	for _, f := range fields {
		c, m, ok := strings.Cut(f, ":")
		if !ok {
			return nil, fmt.Errorf("chip8: bad key event %q", f)
		}
		cycle, err := strconv.ParseUint(c, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("chip8: bad key event cycle %q: %w", f, err)
		}
		mask, err := strconv.ParseUint(m, 16, 16)
		if err != nil || len(m) != 4 {
			return nil, fmt.Errorf("chip8: bad key event mask %q", f)
		}
		if n := len(events); n > 0 && events[n-1].Cycle >= cycle {
			return nil, fmt.Errorf("chip8: key events not strictly increasing at %q", f)
		}
		events = append(events, KeyEvent{Cycle: cycle, Mask: uint16(mask)})
	}
	return events, nil
}
