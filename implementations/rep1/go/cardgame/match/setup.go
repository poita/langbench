// Package match reads Spiremark match files (SPEC section 4) and runs them
// against the engine, producing the program's complete output.
package match

import (
	"errors"
	"strconv"
	"strings"

	"github.com/spiremark/cardgame/engine"
)

// Trace selects the automatic block printed after every accepted action.
type Trace int

// Trace modes.
const (
	TraceNone Trace = iota
	TraceLegal
	TraceState
)

// Setup is the parsed setup block of a match file.
type Setup struct {
	CardsPath string
	Config    engine.Config
	Trace     Trace
	// ScriptStart is the 0-based index of the first line after START.
	ScriptStart int
}

// ErrBadSetup is returned by ParseSetup for any violation of SPEC 4.1.
var ErrBadSetup = errors.New("bad setup")

// splitWords splits on runs of spaces and tabs.
func splitWords(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' })
}

func isComment(line string) bool {
	t := strings.Trim(line, " \t")
	return t == "" || t[0] == '#'
}

// parseUint parses a non-empty run of decimal digits (leading zeros allowed)
// as an unsigned 64-bit value.
func parseUint(s string) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	t := strings.TrimLeft(s, "0")
	if t == "" {
		return 0, true
	}
	v, err := strconv.ParseUint(t, 10, 64)
	return v, err == nil
}

func ranged(s string, lo, hi int) (int, bool) {
	v, ok := parseUint(s)
	if !ok || v < uint64(lo) || v > uint64(hi) {
		return 0, false
	}
	return int(v), true
}

func parseEntries(words []string) ([]engine.CardCount, bool) {
	if len(words) == 0 {
		return nil, false
	}
	out := make([]engine.CardCount, 0, len(words))
	for _, w := range words {
		id, count := w, 1
		if i := strings.IndexByte(w, '*'); i >= 0 {
			id = w[:i]
			c, ok := ranged(w[i+1:], 1, 1000)
			if !ok {
				return nil, false
			}
			count = c
		}
		if id == "" || strings.ContainsRune(id, '*') {
			return nil, false
		}
		out = append(out, engine.CardCount{ID: id, Count: count})
	}
	return out, true
}

// ParseSetup parses the setup block of the match file whose lines are given.
// It returns ErrBadSetup when the block violates SPEC 4.1.
func ParseSetup(lines []string) (*Setup, error) {
	s := &Setup{Config: engine.DefaultConfig()}
	cfg := &s.Config
	seen := map[string]bool{}
	once := func(key string) bool {
		if seen[key] {
			return false
		}
		seen[key] = true
		return true
	}
	started := false
	for i, line := range lines {
		if isComment(line) {
			continue
		}
		w := splitWords(line)
		args := w[1:]
		ok := true
		switch w[0] {
		case "START":
			ok = len(args) == 0 && once("START")
			if ok {
				started = true
				s.ScriptStart = i + 1
			}
		case "CARDS":
			ok = len(args) == 1 && once("CARDS")
			if ok {
				s.CardsPath = args[0]
			}
		case "SEED":
			var v uint64
			v, ok = 0, len(args) == 1
			if ok {
				v, ok = parseUint(args[0])
			}
			ok = ok && once("SEED")
			cfg.Seed = v
		case "SPIRE", "OPENING", "MAXCAP", "HANDMAX", "TURNLIMIT":
			bounds := map[string][2]int{
				"SPIRE": {1, 1000000}, "OPENING": {0, 20}, "MAXCAP": {1, 100},
				"HANDMAX": {0, 100}, "TURNLIMIT": {1, 100000},
			}[w[0]]
			ok = len(args) == 1
			var v int
			if ok {
				v, ok = ranged(args[0], bounds[0], bounds[1])
			}
			ok = ok && once(w[0])
			switch w[0] {
			case "SPIRE":
				cfg.Spire = v
			case "OPENING":
				cfg.Opening = v
			case "MAXCAP":
				cfg.MaxCap = v
			case "HANDMAX":
				cfg.HandMax = v
			case "TURNLIMIT":
				cfg.TurnLimit = v
			}
		case "FIRST":
			ok = len(args) == 1 && (args[0] == "A" || args[0] == "B") && once("FIRST")
			if ok && args[0] == "B" {
				cfg.First = engine.B
			}
		case "SHUFFLE":
			ok = len(args) == 1 && (args[0] == "on" || args[0] == "off") && once("SHUFFLE")
			if ok {
				cfg.Shuffle = args[0] == "on"
			}
		case "TRACE":
			ok = len(args) == 1 && once("TRACE")
			switch {
			case !ok:
			case args[0] == "none":
				s.Trace = TraceNone
			case args[0] == "legal":
				s.Trace = TraceLegal
			case args[0] == "state":
				s.Trace = TraceState
			default:
				ok = false
			}
		case "CAP":
			ok = len(args) == 2 && (args[0] == "A" || args[0] == "B") && once("CAP "+args[0])
			if ok {
				var v int
				v, ok = ranged(args[1], 0, 100)
				if args[0] == "A" {
					cfg.Cap[engine.A] = v
				} else {
					cfg.Cap[engine.B] = v
				}
			}
		case "DECK", "HAND", "FIELD", "ASH", "RIFT":
			ok = len(args) >= 2 && (args[0] == "A" || args[0] == "B")
			if ok {
				var entries []engine.CardCount
				entries, ok = parseEntries(args[1:])
				p := engine.A
				if args[0] == "B" {
					p = engine.B
				}
				switch w[0] {
				case "DECK":
					cfg.Deck[p] = append(cfg.Deck[p], entries...)
				case "HAND":
					cfg.Hand[p] = append(cfg.Hand[p], entries...)
				case "FIELD":
					cfg.Field[p] = append(cfg.Field[p], entries...)
				case "ASH":
					cfg.Ash[p] = append(cfg.Ash[p], entries...)
				case "RIFT":
					cfg.Rift[p] = append(cfg.Rift[p], entries...)
				}
			}
		default:
			ok = false
		}
		if !ok {
			return nil, ErrBadSetup
		}
		if started {
			break
		}
	}
	if !started || !seen["CARDS"] || !seen["SEED"] {
		return nil, ErrBadSetup
	}
	return s, nil
}
