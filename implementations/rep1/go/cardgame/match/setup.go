// Package match parses Spiremark match files: the setup block that precedes
// the START line and the script lines (player actions and inspection
// directives) that follow it.
package match

import (
	"errors"
	"strings"
)

// ErrBadSetup is returned for every violation of the setup-block grammar.
var ErrBadSetup = errors.New("match: bad setup")

// TraceMode selects the block printed after every accepted action.
type TraceMode uint8

// Trace modes.
const (
	TraceNone TraceMode = iota
	TraceLegal
	TraceState
)

// Zone indexes Setup.Zones.
const (
	ZoneDeck = iota
	ZoneHand
	ZoneField
	ZoneAsh
	ZoneRift
	NumSetupZones
)

// Entry is one `<cardid>` or `<cardid>*<count>` entry of a zone line.
type Entry struct {
	CardID string
	Count  int
}

// Setup holds the parsed setup block with defaults applied.
type Setup struct {
	CardsPath string
	Seed      uint64
	Spire     int64
	Opening   int
	MaxCap    int
	HandMax   int
	TurnLimit int
	First     int // 0 for A, 1 for B
	Shuffle   bool
	Trace     TraceMode
	Cap       [2]int
	// Zones[player][zone] lists the entries in the order given.
	Zones [2][NumSetupZones][]Entry
}

// File is a match file split into its setup block and script lines.
type File struct {
	Setup *Setup
	// Script holds the lines after START, each with its 1-based line number
	// in the whole file. Comment lines are included so that numbering is
	// preserved; use Words or IsComment to skip them.
	Script []Line
}

// Line is one input line.
type Line struct {
	No   int
	Text string
}

// SplitLines splits input into lines on '\n', stripping one '\r' before each
// '\n'. A final line without a terminator is still a line.
func SplitLines(data string) []string {
	if data == "" {
		return nil
	}
	parts := strings.Split(data, "\n")
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	for i, p := range parts {
		parts[i] = strings.TrimSuffix(p, "\r")
	}
	return parts
}

// Words splits a line into words on runs of spaces and tabs.
func Words(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' })
}

// IsComment reports whether the line is blank or its first non-space
// character is '#'.
func IsComment(s string) bool {
	t := strings.TrimLeft(s, " \t")
	return t == "" || t[0] == '#'
}

// ParseFile parses a whole match file. It returns ErrBadSetup when the setup
// block is invalid.
func ParseFile(data string) (*File, error) {
	lines := SplitLines(data)
	s := &Setup{
		Spire: 25, Opening: 5, MaxCap: 10, HandMax: 7, TurnLimit: 200, Shuffle: true,
	}
	seen := map[string]bool{}
	haveCards, haveSeed, started := false, false, false
	idx := 0
	for ; idx < len(lines); idx++ {
		if IsComment(lines[idx]) {
			continue
		}
		w := Words(lines[idx])
		if w[0] == "START" {
			if len(w) != 1 {
				return nil, ErrBadSetup
			}
			started = true
			idx++
			break
		}
		if err := s.apply(w, seen, &haveCards, &haveSeed); err != nil {
			return nil, err
		}
	}
	if !started || !haveCards || !haveSeed {
		return nil, ErrBadSetup
	}
	f := &File{Setup: s}
	for ; idx < len(lines); idx++ {
		f.Script = append(f.Script, Line{No: idx + 1, Text: lines[idx]})
	}
	return f, nil
}

func parseNum(s string, max uint64) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	var v uint64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		d := uint64(c - '0')
		if v > (^uint64(0)-d)/10 {
			return 0, false
		}
		v = v*10 + d
	}
	return v, v <= max
}

func playerIdx(s string) (int, bool) {
	switch s {
	case "A":
		return 0, true
	case "B":
		return 1, true
	}
	return 0, false
}

func (s *Setup) apply(w []string, seen map[string]bool, haveCards, haveSeed *bool) error {
	once := func(key string) error {
		if seen[key] {
			return ErrBadSetup
		}
		seen[key] = true
		return nil
	}
	num := func(max uint64) (uint64, error) {
		if len(w) != 2 {
			return 0, ErrBadSetup
		}
		v, ok := parseNum(w[1], max)
		if !ok {
			return 0, ErrBadSetup
		}
		return v, nil
	}
	switch w[0] {
	case "CARDS":
		if len(w) != 2 || once("CARDS") != nil {
			return ErrBadSetup
		}
		s.CardsPath, *haveCards = w[1], true
	case "SEED":
		v, err := num(^uint64(0))
		if err != nil || once("SEED") != nil {
			return ErrBadSetup
		}
		s.Seed, *haveSeed = v, true
	case "SPIRE", "OPENING", "MAXCAP", "HANDMAX", "TURNLIMIT":
		lo, hi := uint64(0), uint64(0)
		switch w[0] {
		case "SPIRE":
			lo, hi = 1, 1000000
		case "OPENING":
			hi = 20
		case "MAXCAP":
			lo, hi = 1, 100
		case "HANDMAX":
			hi = 100
		case "TURNLIMIT":
			lo, hi = 1, 100000
		}
		v, err := num(hi)
		if err != nil || v < lo || once(w[0]) != nil {
			return ErrBadSetup
		}
		switch w[0] {
		case "SPIRE":
			s.Spire = int64(v)
		case "OPENING":
			s.Opening = int(v)
		case "MAXCAP":
			s.MaxCap = int(v)
		case "HANDMAX":
			s.HandMax = int(v)
		case "TURNLIMIT":
			s.TurnLimit = int(v)
		}
	case "FIRST":
		if len(w) != 2 || once("FIRST") != nil {
			return ErrBadSetup
		}
		p, ok := playerIdx(w[1])
		if !ok {
			return ErrBadSetup
		}
		s.First = p
	case "SHUFFLE":
		if len(w) != 2 || once("SHUFFLE") != nil {
			return ErrBadSetup
		}
		switch w[1] {
		case "on":
			s.Shuffle = true
		case "off":
			s.Shuffle = false
		default:
			return ErrBadSetup
		}
	case "TRACE":
		if len(w) != 2 || once("TRACE") != nil {
			return ErrBadSetup
		}
		switch w[1] {
		case "none":
			s.Trace = TraceNone
		case "legal":
			s.Trace = TraceLegal
		case "state":
			s.Trace = TraceState
		default:
			return ErrBadSetup
		}
	case "CAP":
		if len(w) != 3 {
			return ErrBadSetup
		}
		p, ok := playerIdx(w[1])
		v, ok2 := parseNum(w[2], 100)
		if !ok || !ok2 || once("CAP "+w[1]) != nil {
			return ErrBadSetup
		}
		s.Cap[p] = int(v)
	case "DECK", "HAND", "FIELD", "ASH", "RIFT":
		if len(w) < 3 {
			return ErrBadSetup
		}
		p, ok := playerIdx(w[1])
		if !ok {
			return ErrBadSetup
		}
		z := map[string]int{"DECK": ZoneDeck, "HAND": ZoneHand, "FIELD": ZoneField,
			"ASH": ZoneAsh, "RIFT": ZoneRift}[w[0]]
		for _, e := range w[2:] {
			ent, ok := parseEntry(e)
			if !ok {
				return ErrBadSetup
			}
			s.Zones[p][z] = append(s.Zones[p][z], ent)
		}
	default:
		return ErrBadSetup
	}
	return nil
}

func parseEntry(e string) (Entry, bool) {
	i := strings.IndexByte(e, '*')
	if i < 0 {
		return Entry{CardID: e, Count: 1}, e != ""
	}
	if i == 0 {
		return Entry{}, false
	}
	n, ok := parseNum(e[i+1:], 1000)
	if !ok || n < 1 {
		return Entry{}, false
	}
	return Entry{CardID: e[:i], Count: int(n)}, true
}
