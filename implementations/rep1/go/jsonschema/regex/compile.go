package regex

import (
	"strings"
	"sync"
	"unicode/utf8"
)

type opcode uint8

const (
	opRune opcode = iota
	opSet
	opSplit
	opJmp
	opAssert
	opMatch
)

type inst struct {
	op     opcode
	r      rune
	set    *charset
	x, y   int
	assert assertKind
}

// maxProgram bounds the size of a compiled program (counted repetition is
// expanded, so {n,m} multiplies the size of its operand).
const maxProgram = 4_000_000

// Regexp is a compiled pattern. It is safe for concurrent use.
type Regexp struct {
	source   string
	prog     []inst
	literal  string // when isLit, the pattern is exactly this string
	isLit    bool
	anchored bool // every match must start at position 0
	pool     sync.Pool
}

// Compile parses pattern, an ECMA-262 style regular expression restricted to
// the subset described in the package documentation, and compiles it.
func Compile(pattern string) (*Regexp, error) {
	ast, err := parse(pattern)
	if err != nil {
		return nil, err
	}
	re := &Regexp{source: pattern}
	if lit, ok := literalOf(ast); ok {
		re.literal, re.isLit = lit, true
		return re, nil
	}
	c := &compiler{}
	c.emit(ast)
	c.add(inst{op: opMatch})
	if c.tooBig {
		return nil, &SyntaxError{pattern, "pattern too large after expanding repetitions"}
	}
	re.prog = c.prog
	re.anchored = startsAnchored(ast)
	return re, nil
}

// MustCompile is like Compile but panics if the pattern is invalid.
func MustCompile(pattern string) *Regexp {
	re, err := Compile(pattern)
	if err != nil {
		panic(err)
	}
	return re
}

// String returns the source text of the pattern.
func (re *Regexp) String() string { return re.source }

func literalOf(n *node) (string, bool) {
	switch n.kind {
	case nEmpty:
		return "", true
	case nRune:
		return string(n.r), true
	case nCat:
		var sb strings.Builder
		for _, s := range n.subs {
			if s.kind != nRune {
				return "", false
			}
			sb.WriteRune(s.r)
		}
		return sb.String(), true
	}
	return "", false
}

func startsAnchored(n *node) bool {
	switch n.kind {
	case nAssert:
		return n.assert == aBegin
	case nCat:
		return startsAnchored(n.subs[0])
	case nAlt:
		for _, s := range n.subs {
			if !startsAnchored(s) {
				return false
			}
		}
		return true
	case nRepeat:
		return n.min > 0 && startsAnchored(n.subs[0])
	}
	return false
}

type compiler struct {
	prog   []inst
	tooBig bool
}

func (c *compiler) add(i inst) int {
	if len(c.prog) >= maxProgram {
		c.tooBig = true
		return len(c.prog) - 1
	}
	c.prog = append(c.prog, i)
	return len(c.prog) - 1
}

func (c *compiler) emit(n *node) {
	if c.tooBig {
		return
	}
	switch n.kind {
	case nEmpty:
	case nRune:
		c.add(inst{op: opRune, r: n.r})
	case nSet:
		c.add(inst{op: opSet, set: n.set})
	case nAssert:
		c.add(inst{op: opAssert, assert: n.assert})
	case nCat:
		for _, s := range n.subs {
			c.emit(s)
		}
	case nAlt:
		var jumps []int
		for i, s := range n.subs {
			if i == len(n.subs)-1 {
				c.emit(s)
				break
			}
			split := c.add(inst{op: opSplit})
			c.prog[split].x = split + 1
			c.emit(s)
			jumps = append(jumps, c.add(inst{op: opJmp}))
			c.prog[split].y = len(c.prog)
		}
		for _, j := range jumps {
			c.prog[j].x = len(c.prog)
		}
	case nRepeat:
		sub := n.subs[0]
		for i := 0; i < n.min; i++ {
			c.emit(sub)
		}
		if c.tooBig {
			return
		}
		if n.max < 0 {
			split := c.add(inst{op: opSplit})
			c.prog[split].x = split + 1
			c.emit(sub)
			c.add(inst{op: opJmp, x: split})
			c.prog[split].y = len(c.prog)
			return
		}
		var splits []int
		for i := n.min; i < n.max; i++ {
			split := c.add(inst{op: opSplit})
			c.prog[split].x = split + 1
			splits = append(splits, split)
			c.emit(sub)
			if c.tooBig {
				return
			}
		}
		for _, s := range splits {
			c.prog[s].y = len(c.prog)
		}
	}
}

// machine is the reusable scratch state of one match.
type machine struct {
	clist, nlist []int
	stack        []int
	mark         []uint32
	gen          uint32
}

// MatchString reports whether the pattern matches anywhere in s (an unanchored
// search over code points). Matching takes O(len(pattern program) * len(s))
// time: it simulates the program on all positions at once and never backtracks.
func (re *Regexp) MatchString(s string) bool {
	if re.isLit {
		return strings.Contains(s, re.literal)
	}
	m, _ := re.pool.Get().(*machine)
	if m == nil {
		m = &machine{mark: make([]uint32, len(re.prog))}
	}
	ok := re.run(m, s)
	re.pool.Put(m)
	return ok
}

func (m *machine) nextGen() {
	m.gen++
	if m.gen == 0 {
		for i := range m.mark {
			m.mark[i] = 0
		}
		m.gen = 1
	}
}

func (re *Regexp) run(m *machine, s string) bool {
	m.clist = m.clist[:0]
	m.nextGen()
	pos := 0
	prev := rune(-1)
	for {
		cur, size := rune(-1), 0
		if pos < len(s) {
			cur, size = utf8.DecodeRuneInString(s[pos:])
		}
		if pos == 0 || !re.anchored {
			if re.add(m, &m.clist, 0, pos, len(s), prev, cur) {
				return true
			}
		}
		if cur < 0 || len(m.clist) == 0 && re.anchored {
			return false
		}
		next := rune(-1)
		if pos+size < len(s) {
			next, _ = utf8.DecodeRuneInString(s[pos+size:])
		}
		m.nextGen()
		m.nlist = m.nlist[:0]
		for _, pc := range m.clist {
			in := &re.prog[pc]
			if in.op == opRune && in.r == cur || in.op == opSet && in.set.contains(cur) {
				if re.add(m, &m.nlist, pc+1, pos+size, len(s), cur, next) {
					return true
				}
			}
		}
		m.clist, m.nlist = m.nlist, m.clist
		pos += size
		prev = cur
	}
}

// add follows empty transitions from pc at a position with the given context,
// appending character-consuming states to list. It reports whether the match
// state was reached.
func (re *Regexp) add(m *machine, list *[]int, pc, pos, end int, prev, next rune) bool {
	m.stack = append(m.stack[:0], pc)
	for len(m.stack) > 0 {
		pc := m.stack[len(m.stack)-1]
		m.stack = m.stack[:len(m.stack)-1]
		if m.mark[pc] == m.gen {
			continue
		}
		m.mark[pc] = m.gen
		in := &re.prog[pc]
		switch in.op {
		case opJmp:
			m.stack = append(m.stack, in.x)
		case opSplit:
			m.stack = append(m.stack, in.y, in.x)
		case opAssert:
			var ok bool
			switch in.assert {
			case aBegin:
				ok = pos == 0
			case aEnd:
				ok = pos == end
			case aWordB:
				ok = isWordRune(prev) != isWordRune(next)
			case aNotWordB:
				ok = isWordRune(prev) == isWordRune(next)
			}
			if ok {
				m.stack = append(m.stack, pc+1)
			}
		case opMatch:
			return true
		default:
			*list = append(*list, pc)
		}
	}
	return false
}
