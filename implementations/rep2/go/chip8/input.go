package chip8

import (
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// Program is a parsed input: a ROM, a cycle budget and a key schedule.
type Program struct {
	ROM      []byte
	Cycles   uint64
	Schedule KeySchedule
}

// ParseInput parses the textual input format: a line of lowercase ROM hex, a
// line holding the decimal cycle count, and an optional line of key events
// "<cycle>:<mask>" separated by single spaces.
func ParseInput(text string) (*Program, error) {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	lines := strings.Split(text, "\n")
	if len(lines) < 2 {
		return nil, fmt.Errorf("chip8: input needs a ROM line and a cycle line")
	}
	rom, err := hex.DecodeString(strings.TrimSpace(lines[0]))
	if err != nil {
		return nil, fmt.Errorf("chip8: bad ROM: %w", err)
	}
	if len(rom) == 0 || len(rom) > MaxROMSize {
		return nil, fmt.Errorf("chip8: ROM size %d out of range", len(rom))
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

// ParseSchedule parses a space-separated list of "<cycle>:<mask>" events. An
// empty string yields an empty schedule.
func ParseSchedule(s string) (KeySchedule, error) {
	var sched KeySchedule
	for _, field := range strings.Fields(s) {
		c, m, ok := strings.Cut(field, ":")
		if !ok {
			return nil, fmt.Errorf("chip8: bad key event %q", field)
		}
		cycle, err := strconv.ParseUint(c, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("chip8: bad key event cycle %q: %w", field, err)
		}
		if len(m) != 4 {
			return nil, fmt.Errorf("chip8: key event mask %q must be four hex digits", field)
		}
		mask, err := strconv.ParseUint(m, 16, 16)
		if err != nil {
			return nil, fmt.Errorf("chip8: bad key event mask %q: %w", field, err)
		}
		if n := len(sched); n > 0 && sched[n-1].Cycle >= cycle {
			return nil, fmt.Errorf("chip8: key event cycles not strictly increasing at %q", field)
		}
		sched = append(sched, KeyEvent{Cycle: cycle, Mask: uint16(mask)})
	}
	return sched, nil
}

// Execute builds a fresh machine, loads the program, runs it for its cycle
// budget and returns the final machine.
func (p *Program) Execute() (*Machine, error) {
	m := New()
	if err := m.LoadROM(p.ROM); err != nil {
		return nil, err
	}
	m.Run(p.Cycles, p.Schedule)
	return m, nil
}
