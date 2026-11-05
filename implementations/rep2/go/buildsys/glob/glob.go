// Package glob compiles and matches Kiln glob patterns.
//
// A pattern is a "/"-separated list of components. The component "**"
// matches zero or more whole candidate components; any other component is a
// sequence of literal bytes, "?", "*" and "[...]" character classes that
// never matches across a "/".
package glob

import "errors"

// ErrBadPattern is returned by Compile for a malformed pattern.
var ErrBadPattern = errors.New("glob: bad pattern")

type itemKind uint8

const (
	itLit itemKind = iota
	itAny
	itStar
	itClass
)

type item struct {
	kind itemKind
	b    byte
	set  *[4]uint64 // for itClass: membership bitmap (negation applied)
}

func (it *item) classHas(c byte) bool { return it.set[c>>6]&(1<<(c&63)) != 0 }

type component struct {
	double bool // exactly "**"
	items  []item
}

// Pattern is a compiled glob pattern. A Pattern keeps scratch memory for
// matching, so it must not be used from several goroutines at once.
type Pattern struct {
	comps   []component
	doubles int
	prefix  string
	memo    []bool
	memoW   int
}

// Compile parses pattern. It returns ErrBadPattern if the pattern is empty,
// has a leading or trailing "/", an empty component, or a malformed class.
func Compile(pattern string) (*Pattern, error) {
	if pattern == "" {
		return nil, ErrBadPattern
	}
	p := &Pattern{}
	start := 0
	for i := 0; i <= len(pattern); i++ {
		if i < len(pattern) && pattern[i] != '/' {
			continue
		}
		part := pattern[start:i]
		if part == "" {
			return nil, ErrBadPattern
		}
		start = i + 1
		if part == "**" {
			// Consecutive "**" components are equivalent to one.
			if n := len(p.comps); n > 0 && p.comps[n-1].double {
				continue
			}
			p.comps = append(p.comps, component{double: true})
			p.doubles++
			continue
		}
		items, err := compileComponent(part)
		if err != nil {
			return nil, err
		}
		p.comps = append(p.comps, component{items: items})
	}
	p.prefix = literalPrefix(pattern)
	return p, nil
}

func compileComponent(s string) ([]item, error) {
	var items []item
	for i := 0; i < len(s); {
		switch c := s[i]; c {
		case '*':
			// Collapse runs of '*'.
			if n := len(items); n == 0 || items[n-1].kind != itStar {
				items = append(items, item{kind: itStar})
			}
			i++
		case '?':
			items = append(items, item{kind: itAny})
			i++
		case '[':
			it, next, err := compileClass(s, i+1)
			if err != nil {
				return nil, err
			}
			items = append(items, it)
			i = next
		default:
			items = append(items, item{kind: itLit, b: c})
			i++
		}
	}
	return items, nil
}

// compileClass parses a class whose body starts at s[i] (just after '[').
// It returns the item and the index just past the closing ']'.
func compileClass(s string, i int) (item, int, error) {
	neg := false
	if i < len(s) && s[i] == '!' {
		neg = true
		i++
	}
	var set [4]uint64
	add := func(lo, hi byte) {
		for c := int(lo); c <= int(hi); c++ {
			set[c>>6] |= 1 << (uint(c) & 63)
		}
	}
	n := 0
	for {
		if i >= len(s) {
			return item{}, 0, ErrBadPattern
		}
		if s[i] == ']' {
			if n == 0 {
				return item{}, 0, ErrBadPattern
			}
			i++
			break
		}
		if i+2 < len(s) && s[i+1] == '-' && s[i+2] != ']' {
			if s[i] > s[i+2] {
				return item{}, 0, ErrBadPattern
			}
			add(s[i], s[i+2])
			i += 3
		} else {
			add(s[i], s[i])
			i++
		}
		n++
	}
	if neg {
		for k := range set {
			set[k] = ^set[k]
		}
	}
	return item{kind: itClass, set: &set}, i, nil
}

// literalPrefix joins the leading components that contain no '*', '?' or '['.
func literalPrefix(pattern string) string {
	end := 0
	start := 0
	for i := 0; i <= len(pattern); i++ {
		if i < len(pattern) && pattern[i] != '/' {
			continue
		}
		for j := start; j < i; j++ {
			if c := pattern[j]; c == '*' || c == '?' || c == '[' {
				return pattern[:end]
			}
		}
		end = i
		start = i + 1
	}
	return pattern[:end]
}

// LiteralPrefix returns the leading pattern components that contain no
// wildcard, joined with "/" and with no trailing "/". Every path the
// pattern matches starts with this byte prefix, which makes it usable to
// narrow a sorted list of candidates.
func (p *Pattern) LiteralPrefix() string { return p.prefix }

// Match reports whether the pattern matches the whole of s, which is split
// at every "/" into components (empty components are kept).
func (p *Pattern) Match(s string) bool {
	ncomp := 1
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			ncomp++
		}
	}
	if p.doubles >= 2 {
		w := ncomp + 1
		need := (len(p.comps) + 1) * w
		if cap(p.memo) < need {
			p.memo = make([]bool, need)
		} else {
			p.memo = p.memo[:need]
			clear(p.memo)
		}
		p.memoW = w
	}
	return p.match(0, 0, 0, s, ncomp)
}

// match matches pattern components pi.. against candidate components ci..
// ncomp-1, where candidate component ci starts at byte offset off.
func (p *Pattern) match(pi, ci, off int, s string, ncomp int) bool {
	for {
		if pi == len(p.comps) {
			return ci == ncomp
		}
		c := &p.comps[pi]
		if !c.double {
			if ci == ncomp {
				return false
			}
			end := off
			for end < len(s) && s[end] != '/' {
				end++
			}
			if !matchItems(c.items, s[off:end]) {
				return false
			}
			pi++
			ci++
			off = end + 1
			continue
		}
		if pi == len(p.comps)-1 {
			return true
		}
		if p.doubles >= 2 {
			k := pi*p.memoW + ci
			if p.memo[k] {
				return false
			}
			p.memo[k] = true
		}
		// "**" consumes zero or more components.
		for {
			if p.match(pi+1, ci, off, s, ncomp) {
				return true
			}
			if ci == ncomp {
				return false
			}
			for off < len(s) && s[off] != '/' {
				off++
			}
			off++
			ci++
		}
	}
}

// matchItems matches one component's items against one candidate component
// using linear star backtracking.
func matchItems(items []item, s string) bool {
	ii, si := 0, 0
	starI, starS := -1, 0
	for si < len(s) {
		if ii < len(items) {
			it := &items[ii]
			switch it.kind {
			case itStar:
				starI, starS = ii, si
				ii++
				continue
			case itAny:
				ii++
				si++
				continue
			case itLit:
				if s[si] == it.b {
					ii++
					si++
					continue
				}
			case itClass:
				if it.classHas(s[si]) {
					ii++
					si++
					continue
				}
			}
		}
		if starI < 0 {
			return false
		}
		starS++
		si = starS
		ii = starI + 1
	}
	for ii < len(items) && items[ii].kind == itStar {
		ii++
	}
	return ii == len(items)
}
