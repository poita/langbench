package chip8

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Program is a parsed run request: a ROM, a cycle budget and a key schedule.
type Program struct {
	ROM      []byte
	Cycles   uint64
	Schedule KeySchedule
}

// ParseProgram parses the textual input format: a lowercase-hex ROM line, a
// decimal cycle count line and an optional key schedule line of
// space-separated "<cycle>:<mask>" events.
func ParseProgram(r io.Reader) (*Program, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\r\n"), "\n")
	if len(lines) < 2 {
		return nil, errors.New("chip8: input needs a ROM line and a cycle count line")
	}
	rom, err := hex.DecodeString(strings.TrimSpace(lines[0]))
	if err != nil {
		return nil, fmt.Errorf("chip8: bad ROM: %w", err)
	}
	if len(rom) == 0 {
		return nil, errors.New("chip8: empty ROM")
	}
	cycles, err := strconv.ParseUint(strings.TrimSpace(lines[1]), 10, 64)
	if err != nil {
		return nil, fmt.Errorf("chip8: bad cycle count: %w", err)
	}
	p := &Program{ROM: rom, Cycles: cycles}
	if len(lines) > 2 {
		if p.Schedule, err = ParseSchedule(lines[2]); err != nil {
			return nil, err
		}
	}
	return p, nil
}

// ParseSchedule parses a key schedule line such as "9:0300 20:0000".
// An empty line yields an empty schedule.
func ParseSchedule(s string) (KeySchedule, error) {
	var sched KeySchedule
	for _, f := range strings.Fields(s) {
		c, m, ok := strings.Cut(f, ":")
		if !ok {
			return nil, fmt.Errorf("chip8: bad key event %q", f)
		}
		cycle, err := strconv.ParseUint(c, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("chip8: bad key event cycle %q: %w", f, err)
		}
		mask, err := strconv.ParseUint(m, 16, 16)
		if err != nil {
			return nil, fmt.Errorf("chip8: bad key event mask %q: %w", f, err)
		}
		sched = append(sched, KeyEvent{Cycle: cycle, Mask: uint16(mask)})
	}
	if !sched.Valid() {
		return nil, errors.New("chip8: key events must be in strictly increasing cycle order")
	}
	return sched, nil
}

// Execute builds a machine for p, runs it to completion and returns it.
func (p *Program) Execute() (*Machine, error) {
	m, err := New(p.ROM)
	if err != nil {
		return nil, err
	}
	m.Run(p.Cycles, p.Schedule)
	return m, nil
}
