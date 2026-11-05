package match

import "errors"

// ErrBadSyntax is returned for a script line that is not a well-formed
// action or directive.
var ErrBadSyntax = errors.New("match: bad syntax")

// CmdKind is the kind of a script command.
type CmdKind uint8

// Command kinds.
const (
	CmdPass CmdKind = iota
	CmdConcede
	CmdPlay
	CmdAct
	CmdAttack
	CmdBlock
	CmdDump
	CmdLegal
	CmdVault
	CmdCard
)

// IsAction reports whether the kind is a player action (as opposed to an
// inspection directive).
func (k CmdKind) IsAction() bool { return k <= CmdBlock }

// TokKind is the kind of a target token.
type TokKind uint8

// Target token kinds.
const (
	TokPlayer TokKind = iota // N is 0 for A, 1 for B
	TokObject                // #N
	TokChain                 // ~N
)

// Token is one target as written in a PLAY or ACT command.
type Token struct {
	Kind TokKind
	N    uint64
}

// Pair is one blocker:attacker pair of a BLOCK command.
type Pair struct{ Blocker, Attacker uint64 }

// Cmd is a parsed script command.
type Cmd struct {
	Kind    CmdKind
	Player  int    // acting player for actions
	Pos     uint64 // PLAY hand position
	Obj     uint64 // ACT source object
	Index   uint64 // ACT ability number
	Targets []Token
	Objs    []uint64 // ATTACK attackers
	Pairs   []Pair   // BLOCK pairs
	CardID  string   // CARD directive argument
}

func decimal(s string) (uint64, bool) { return parseNum(s, ^uint64(0)) }

func objref(s string) (uint64, bool) {
	if len(s) < 2 || s[0] != '#' {
		return 0, false
	}
	return decimal(s[1:])
}

func target(s string) (Token, bool) {
	switch {
	case s == "A":
		return Token{TokPlayer, 0}, true
	case s == "B":
		return Token{TokPlayer, 1}, true
	case len(s) >= 2 && s[0] == '#':
		n, ok := decimal(s[1:])
		return Token{TokObject, n}, ok
	case len(s) >= 2 && s[0] == '~':
		n, ok := decimal(s[1:])
		return Token{TokChain, n}, ok
	}
	return Token{}, false
}

func targets(ws []string) ([]Token, bool) {
	var out []Token
	for _, w := range ws {
		t, ok := target(w)
		if !ok {
			return nil, false
		}
		out = append(out, t)
	}
	return out, true
}

// ParseCommand parses one non-comment script line.
func ParseCommand(line string) (Cmd, error) {
	w := Words(line)
	if len(w) == 0 {
		return Cmd{}, ErrBadSyntax
	}
	switch w[0] {
	case "DUMP", "LEGAL", "VAULT":
		if len(w) != 1 {
			return Cmd{}, ErrBadSyntax
		}
		return Cmd{Kind: map[string]CmdKind{"DUMP": CmdDump, "LEGAL": CmdLegal, "VAULT": CmdVault}[w[0]]}, nil
	case "CARD":
		if len(w) != 2 {
			return Cmd{}, ErrBadSyntax
		}
		return Cmd{Kind: CmdCard, CardID: w[1]}, nil
	}
	p, ok := playerIdx(w[0])
	if !ok || len(w) < 2 {
		return Cmd{}, ErrBadSyntax
	}
	c := Cmd{Player: p}
	args := w[2:]
	switch w[1] {
	case "PASS", "CONCEDE":
		if len(args) != 0 {
			return Cmd{}, ErrBadSyntax
		}
		c.Kind = CmdPass
		if w[1] == "CONCEDE" {
			c.Kind = CmdConcede
		}
	case "PLAY":
		if len(args) < 1 {
			return Cmd{}, ErrBadSyntax
		}
		pos, ok := decimal(args[0])
		if !ok {
			return Cmd{}, ErrBadSyntax
		}
		ts, ok := targets(args[1:])
		if !ok {
			return Cmd{}, ErrBadSyntax
		}
		c.Kind, c.Pos, c.Targets = CmdPlay, pos, ts
	case "ACT":
		if len(args) < 2 {
			return Cmd{}, ErrBadSyntax
		}
		obj, ok := objref(args[0])
		idx, ok2 := decimal(args[1])
		ts, ok3 := targets(args[2:])
		if !ok || !ok2 || !ok3 {
			return Cmd{}, ErrBadSyntax
		}
		c.Kind, c.Obj, c.Index, c.Targets = CmdAct, obj, idx, ts
	case "ATTACK":
		c.Kind = CmdAttack
		for _, a := range args {
			o, ok := objref(a)
			if !ok {
				return Cmd{}, ErrBadSyntax
			}
			c.Objs = append(c.Objs, o)
		}
	case "BLOCK":
		c.Kind = CmdBlock
		for _, a := range args {
			var l, r string
			for i := 0; i < len(a); i++ {
				if a[i] == ':' {
					l, r = a[:i], a[i+1:]
					break
				}
			}
			b, ok := objref(l)
			at, ok2 := objref(r)
			if !ok || !ok2 {
				return Cmd{}, ErrBadSyntax
			}
			c.Pairs = append(c.Pairs, Pair{b, at})
		}
	default:
		return Cmd{}, ErrBadSyntax
	}
	return c, nil
}
