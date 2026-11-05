package chip8

import (
	"errors"
	"fmt"
	"io"
	"strings"
)

// Limits of the input format.
const (
	ProgramStart = 0x200
	MaxROMSize   = 4096 - ProgramStart
	MaxCycles    = 4000000000
)

// KeyEvent changes the 16-bit key state immediately before cycle Cycle runs.
// Bit k of Mask set means key k is held down.
type KeyEvent struct {
	Cycle uint64
	Mask  uint16
}

// Input is a parsed program description.
type Input struct {
	ROM    []byte
	Cycles uint64
	Events []KeyEvent
}

// ParseInput reads the whole of r and parses it: a hex ROM line, a decimal
// cycle count line and an optional key-schedule line.
func ParseInput(r io.Reader) (*Input, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return ParseInputString(string(data))
}

// ParseInputString parses the input format from a string.
func ParseInputString(s string) (*Input, error) {
	s = strings.TrimSuffix(s, "\n")
	lines := strings.SplitN(s, "\n", 3)
	if len(lines) < 2 {
		return nil, errors.New("chip8: input needs a ROM line and a cycle line")
	}
	in := &Input{}
	var err error
	if in.ROM, err = ParseROM(lines[0]); err != nil {
		return nil, err
	}
	n, err := parseDecimal(lines[1])
	if err != nil {
		return nil, fmt.Errorf("chip8: cycle count: %w", err)
	}
	if n > MaxCycles {
		return nil, fmt.Errorf("chip8: cycle count %d exceeds %d", n, uint64(MaxCycles))
	}
	in.Cycles = n
	if len(lines) == 3 {
		if in.Events, err = ParseKeySchedule(lines[2]); err != nil {
			return nil, err
		}
	}
	return in, nil
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

// ParseROM converts a hexadecimal string (two digits per byte) into bytes.
func ParseROM(s string) ([]byte, error) {
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

func parseDecimal(s string) (uint64, error) {
	if s == "" || len(s) > 19 {
		return 0, errors.New("invalid decimal number")
	}
	var n uint64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("invalid decimal number %q", s)
		}
		n = n*10 + uint64(c-'0')
	}
	return n, nil
}

// ParseKeySchedule parses space-separated "<cycle>:<mask>" events. An empty
// string yields no events. Cycles must be strictly increasing.
func ParseKeySchedule(s string) ([]KeyEvent, error) {
	if s == "" {
		return nil, nil
	}
	fields := strings.Split(s, " ")
	events := make([]KeyEvent, 0, len(fields))
	for _, f := range fields {
		c, m, ok := strings.Cut(f, ":")
		if !ok || len(m) != 4 {
			return nil, fmt.Errorf("chip8: bad key event %q", f)
		}
		cycle, err := parseDecimal(c)
		if err != nil {
			return nil, fmt.Errorf("chip8: key event %q: %w", f, err)
		}
		var mask uint16
		for i := 0; i < 4; i++ {
			v, ok := hexVal(m[i])
			if !ok {
				return nil, fmt.Errorf("chip8: bad key mask in %q", f)
			}
			mask = mask<<4 | uint16(v)
		}
		if n := len(events); n > 0 && events[n-1].Cycle >= cycle {
			return nil, fmt.Errorf("chip8: key event cycles not strictly increasing at %q", f)
		}
		events = append(events, KeyEvent{Cycle: cycle, Mask: mask})
	}
	return events, nil
}
