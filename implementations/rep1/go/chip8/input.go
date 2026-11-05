package chip8

import (
	"errors"
	"fmt"
	"strings"
)

// MaxCycles is the largest cycle budget accepted by ParseInput.
const MaxCycles = 4000000000

// Program is a parsed problem input: a ROM, a cycle budget and a key schedule.
type Program struct {
	ROM    []byte
	Cycles uint64
	Events []KeyEvent
}

// ParseInput parses the textual input format: a lowercase-hex ROM line, a
// decimal cycle count line and an optional key schedule line of
// space-separated "<cycle>:<mask>" events with a four-digit hex mask.
func ParseInput(data []byte) (*Program, error) {
	text := strings.TrimRight(string(data), "\r\n")
	lines := strings.Split(text, "\n")
	if len(lines) < 2 || len(lines) > 3 {
		return nil, fmt.Errorf("chip8: expected 2 or 3 input lines, got %d", len(lines))
	}
	p := &Program{}

	hexLine := strings.TrimSpace(lines[0])
	if len(hexLine) == 0 || len(hexLine)%2 != 0 {
		return nil, errors.New("chip8: ROM must have an even, non-zero number of hex digits")
	}
	if len(hexLine)/2 > MaxROMSize {
		return nil, fmt.Errorf("chip8: ROM exceeds %d bytes", MaxROMSize)
	}
	p.ROM = make([]byte, len(hexLine)/2)
	for i := range p.ROM {
		hi, ok1 := hexVal(hexLine[2*i])
		lo, ok2 := hexVal(hexLine[2*i+1])
		if !ok1 || !ok2 {
			return nil, fmt.Errorf("chip8: invalid hex digit in ROM near offset %d", 2*i)
		}
		p.ROM[i] = hi<<4 | lo
	}

	n, rest, err := parseDecimal(strings.TrimSpace(lines[1]))
	if err != nil || rest != "" {
		return nil, fmt.Errorf("chip8: invalid cycle count %q", lines[1])
	}
	if n > MaxCycles {
		return nil, fmt.Errorf("chip8: cycle count %d exceeds %d", n, uint64(MaxCycles))
	}
	p.Cycles = n

	if len(lines) == 3 {
		p.Events, err = ParseSchedule(strings.TrimSpace(lines[2]))
		if err != nil {
			return nil, err
		}
	}
	return p, nil
}

// ParseSchedule parses a key schedule line such as "9:0300 20:0000".
// An empty string yields no events. Cycles must be strictly increasing.
func ParseSchedule(s string) ([]KeyEvent, error) {
	if s == "" {
		return nil, nil
	}
	var events []KeyEvent
	for _, f := range strings.Fields(s) {
		c, rest, err := parseDecimal(f)
		if err != nil || len(rest) != 5 || rest[0] != ':' {
			return nil, fmt.Errorf("chip8: invalid key event %q", f)
		}
		var mask uint16
		for i := 1; i < 5; i++ {
			d, ok := hexVal(rest[i])
			if !ok {
				return nil, fmt.Errorf("chip8: invalid key mask in event %q", f)
			}
			mask = mask<<4 | uint16(d)
		}
		if len(events) > 0 && c <= events[len(events)-1].Cycle {
			return nil, fmt.Errorf("chip8: key event cycles must be strictly increasing (at %q)", f)
		}
		events = append(events, KeyEvent{Cycle: c, Mask: mask})
	}
	return events, nil
}

// parseDecimal reads a leading run of decimal digits from s and returns its
// value and the remainder of s.
func parseDecimal(s string) (uint64, string, error) {
	i := 0
	var n uint64
	for ; i < len(s) && s[i] >= '0' && s[i] <= '9'; i++ {
		if n > (1<<63)/10 {
			return 0, "", errors.New("chip8: number too large")
		}
		n = n*10 + uint64(s[i]-'0')
	}
	if i == 0 {
		return 0, "", errors.New("chip8: expected a decimal number")
	}
	return n, s[i:], nil
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

// Run builds a machine with the program's ROM loaded and runs it for the
// program's cycle budget under its key schedule.
func (p *Program) Run() (*Machine, error) {
	m := New()
	if err := m.LoadROM(p.ROM); err != nil {
		return nil, err
	}
	m.RunSchedule(p.Cycles, p.Events)
	return m, nil
}
