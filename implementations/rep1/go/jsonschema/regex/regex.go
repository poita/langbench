package regex

import (
	"strings"
	"sync"
)

type opcode uint8

const (
	opChar opcode = iota
	opAny
	opClass
	opSplit // try x first, then y
	opJmp
	opBol
	opEol
	opWordB
	opNotWordB
	opMatch
)

type inst struct {
	op     opcode
	r      rune
	ranges []rng
	neg    bool
	x, y   int
}

// maxProgram bounds the compiled program size.
const maxProgram = 4_000_000

// Regexp is a compiled pattern. It is safe for concurrent use.
type Regexp struct {
	pattern  string
	prog     []inst
	literal  string // non-empty: the pattern is exactly this literal text
	isLit    bool
	anchored bool // every match must start at position 0
}

// Compile parses and compiles an ECMA-262 pattern (see the package comment
// for the supported subset).
func Compile(pattern string) (*Regexp, error) {
	tree, err := parse(pattern)
	if err != nil {
		return nil, err
	}
	re := &Regexp{pattern: pattern}
	if lit, ok := literalOf(tree); ok {
		re.literal, re.isLit = lit, true
		return re, nil
	}
	c := &compiler{}
	c.emitNode(tree)
	c.emit(inst{op: opMatch})
	if c.tooBig {
		return nil, &SyntaxError{Pattern: pattern, Msg: "pattern too large"}
	}
	re.prog = c.prog
	re.anchored = re.prog[0].op == opBol
	return re, nil
}

// MustCompile is like Compile but panics on error.
func MustCompile(pattern string) *Regexp {
	re, err := Compile(pattern)
	if err != nil {
		panic(err)
	}
	return re
}

// String returns the source text of the pattern.
func (re *Regexp) String() string { return re.pattern }

// literalOf reports whether the tree is a plain sequence of characters.
func literalOf(n *node) (string, bool) {
	switch n.kind {
	case nEmpty:
		return "", true
	case nChar:
		if n.r >= 0xD800 && n.r < 0xE000 {
			return "", false
		}
		return string(n.r), true
	case nConcat:
		var b strings.Builder
		for _, s := range n.subs {
			if s.kind != nChar || (s.r >= 0xD800 && s.r < 0xE000) {
				return "", false
			}
			b.WriteRune(s.r)
		}
		return b.String(), true
	}
	return "", false
}

type compiler struct {
	prog   []inst
	tooBig bool
}

func (c *compiler) emit(i inst) int {
	if len(c.prog) >= maxProgram {
		c.tooBig = true
		return len(c.prog) - 1
	}
	c.prog = append(c.prog, i)
	return len(c.prog) - 1
}

func (c *compiler) emitNode(n *node) {
	if c.tooBig {
		return
	}
	switch n.kind {
	case nEmpty:
	case nChar:
		c.emit(inst{op: opChar, r: n.r})
	case nAny:
		c.emit(inst{op: opAny})
	case nClass:
		c.emit(inst{op: opClass, ranges: n.ranges, neg: n.neg})
	case nBol:
		c.emit(inst{op: opBol})
	case nEol:
		c.emit(inst{op: opEol})
	case nWordB:
		c.emit(inst{op: opWordB})
	case nNotWordB:
		c.emit(inst{op: opNotWordB})
	case nConcat:
		for _, s := range n.subs {
			c.emitNode(s)
		}
	case nAlt:
		// split L1, L2; L1: a; jmp end; L2: split ...; last
		var jumps []int
		for i, s := range n.subs {
			if i < len(n.subs)-1 {
				split := c.emit(inst{op: opSplit})
				c.prog[split].x = len(c.prog)
				c.emitNode(s)
				jumps = append(jumps, c.emit(inst{op: opJmp}))
				c.prog[split].y = len(c.prog)
			} else {
				c.emitNode(s)
			}
		}
		for _, j := range jumps {
			c.prog[j].x = len(c.prog)
		}
	case nRepeat:
		sub := n.subs[0]
		for i := 0; i < n.min; i++ {
			c.emitNode(sub)
		}
		if n.max < 0 {
			// L1: split L2, L3; L2: sub; jmp L1; L3:
			split := c.emit(inst{op: opSplit})
			c.prog[split].x = len(c.prog)
			c.emitNode(sub)
			c.emit(inst{op: opJmp, x: split})
			c.prog[split].y = len(c.prog)
			return
		}
		// (max-min) nested optional copies: split body, end
		var splits []int
		for i := n.min; i < n.max; i++ {
			s := c.emit(inst{op: opSplit})
			c.prog[s].x = len(c.prog)
			splits = append(splits, s)
			c.emitNode(sub)
		}
		for _, s := range splits {
			c.prog[s].y = len(c.prog)
		}
	}
}

// matcher holds reusable scratch memory for one match call.
type matcher struct {
	runes   []rune
	visited []uint64
	stack   []frame
}

type frame struct{ pc, pos int }

var matcherPool = sync.Pool{New: func() any { return new(matcher) }}

// MatchString reports whether the pattern matches anywhere in s (an
// unanchored search; use ^ and $ to anchor).
func (re *Regexp) MatchString(s string) bool {
	if re.isLit {
		return strings.Contains(s, re.literal)
	}
	m := matcherPool.Get().(*matcher)
	defer matcherPool.Put(m)
	m.runes = m.runes[:0]
	for _, r := range s {
		m.runes = append(m.runes, r)
	}
	return re.search(m)
}

func isWord(r rune) bool {
	return r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}

func (re *Regexp) search(m *matcher) bool {
	n := len(m.runes)
	width := n + 1
	words := (len(re.prog)*width + 63) / 64
	if cap(m.visited) < words {
		m.visited = make([]uint64, words)
	} else {
		m.visited = m.visited[:words]
		clear(m.visited)
	}
	last := n
	if re.anchored {
		last = 0
	}
	for start := 0; start <= last; start++ {
		if re.run(m, start, width) {
			return true
		}
	}
	return false
}

func (re *Regexp) run(m *matcher, start, width int) bool {
	prog, runes, n := re.prog, m.runes, len(m.runes)
	m.stack = append(m.stack[:0], frame{0, start})
	for len(m.stack) > 0 {
		f := m.stack[len(m.stack)-1]
		m.stack = m.stack[:len(m.stack)-1]
		pc, pos := f.pc, f.pos
	thread:
		for {
			idx := pc*width + pos
			if m.visited[idx>>6]&(1<<(idx&63)) != 0 {
				break
			}
			m.visited[idx>>6] |= 1 << (idx & 63)
			in := &prog[pc]
			switch in.op {
			case opChar:
				if pos < n && runes[pos] == in.r {
					pc++
					pos++
					continue
				}
				break thread
			case opAny:
				if pos < n {
					if r := runes[pos]; r != '\n' && r != '\r' && r != 0x2028 && r != 0x2029 {
						pc++
						pos++
						continue
					}
				}
				break thread
			case opClass:
				if pos < n && inRanges(in.ranges, runes[pos]) != in.neg {
					pc++
					pos++
					continue
				}
				break thread
			case opSplit:
				m.stack = append(m.stack, frame{in.y, pos})
				pc = in.x
			case opJmp:
				pc = in.x
			case opBol:
				if pos != 0 {
					break thread
				}
				pc++
			case opEol:
				if pos != n {
					break thread
				}
				pc++
			case opWordB, opNotWordB:
				before := pos > 0 && isWord(runes[pos-1])
				after := pos < n && isWord(runes[pos])
				if (before != after) != (in.op == opWordB) {
					break thread
				}
				pc++
			case opMatch:
				return true
			}
		}
	}
	return false
}

func inRanges(rs []rng, r rune) bool {
	if len(rs) <= 8 {
		for _, x := range rs {
			if r >= x.lo && r <= x.hi {
				return true
			}
		}
		return false
	}
	lo, hi := 0, len(rs)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case r < rs[mid].lo:
			hi = mid
		case r > rs[mid].hi:
			lo = mid + 1
		default:
			return true
		}
	}
	return false
}
