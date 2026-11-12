// Package glob implements Kiln's glob patterns.
//
// A pattern is split on "/" into components. "**" as a whole component matches
// zero or more candidate components; inside any other component "*" matches
// any run of bytes, "?" one byte, and "[...]" a character class. Matching is
// purely byte based and never crosses a "/" inside a component.
package glob

import (
	"errors"
	"strings"
)

// ErrBadPattern is returned by Compile for a malformed pattern.
var ErrBadPattern = errors.New("glob: bad pattern")

type itemKind uint8

const (
	itemLit  itemKind = iota
	itemAny           // ?
	itemStar          // *
	itemSet           // [...]
)

type item struct {
	kind itemKind
	lit  byte
	set  *[256]bool
}

type component struct {
	doubleStar bool
	items      []item
}

// Pattern is a compiled glob pattern.
type Pattern struct {
	comps    []component
	hasDStar bool
}

// Compile parses pattern, returning ErrBadPattern if it is malformed: empty,
// with a leading or trailing "/", with an empty component, or containing a
// malformed character class.
func Compile(pattern string) (*Pattern, error) {
	if pattern == "" {
		return nil, ErrBadPattern
	}
	parts := strings.Split(pattern, "/")
	p := &Pattern{comps: make([]component, 0, len(parts))}
	for _, part := range parts {
		if part == "" {
			return nil, ErrBadPattern
		}
		if part == "**" {
			p.comps = append(p.comps, component{doubleStar: true})
			p.hasDStar = true
			continue
		}
		items, err := compileComponent(part)
		if err != nil {
			return nil, err
		}
		p.comps = append(p.comps, component{items: items})
	}
	return p, nil
}

func compileComponent(s string) ([]item, error) {
	var items []item
	for i := 0; i < len(s); {
		switch c := s[i]; c {
		case '*':
			// Collapse runs of stars; they are equivalent to one.
			if n := len(items); n == 0 || items[n-1].kind != itemStar {
				items = append(items, item{kind: itemStar})
			}
			i++
		case '?':
			items = append(items, item{kind: itemAny})
			i++
		case '[':
			set, next, err := compileClass(s, i+1)
			if err != nil {
				return nil, err
			}
			items = append(items, item{kind: itemSet, set: set})
			i = next
		default:
			items = append(items, item{kind: itemLit, lit: c})
			i++
		}
	}
	return items, nil
}

// compileClass parses a character class whose body starts at s[i] (just after
// the "["), returning the byte set and the index after the closing "]".
func compileClass(s string, i int) (*[256]bool, int, error) {
	negate := false
	if i < len(s) && s[i] == '!' {
		negate = true
		i++
	}
	var set [256]bool
	count := 0
	for {
		if i >= len(s) {
			return nil, 0, ErrBadPattern
		}
		if s[i] == ']' {
			if count == 0 {
				return nil, 0, ErrBadPattern
			}
			i++
			break
		}
		if i+2 < len(s) && s[i+1] == '-' && s[i+2] != ']' {
			lo, hi := s[i], s[i+2]
			if lo > hi {
				return nil, 0, ErrBadPattern
			}
			for b := int(lo); b <= int(hi); b++ {
				set[b] = true
			}
			i += 3
		} else {
			set[s[i]] = true
			i++
		}
		count++
	}
	if negate {
		for b := range set {
			set[b] = !set[b]
		}
	}
	return &set, i, nil
}

// Match reports whether the pattern matches the whole candidate string. The
// candidate is split at every "/" and empty components are kept.
func (p *Pattern) Match(candidate string) bool {
	cands := strings.Split(candidate, "/")
	if !p.hasDStar {
		if len(cands) != len(p.comps) {
			return false
		}
		for i, c := range p.comps {
			if !matchComponent(c.items, cands[i]) {
				return false
			}
		}
		return true
	}
	// dp[j] reports whether pattern components i.. match candidate components
	// j.. ; computed from the last pattern component backwards.
	n := len(cands)
	next := make([]bool, n+1)
	next[n] = true // empty pattern suffix matches the empty candidate suffix
	cur := make([]bool, n+1)
	for i := len(p.comps) - 1; i >= 0; i-- {
		c := p.comps[i]
		if c.doubleStar {
			cur[n] = next[n]
			for j := n - 1; j >= 0; j-- {
				cur[j] = next[j] || cur[j+1]
			}
		} else {
			cur[n] = false
			for j := n - 1; j >= 0; j-- {
				cur[j] = next[j+1] && matchComponent(c.items, cands[j])
			}
		}
		cur, next = next, cur
	}
	return next[0]
}

// matchComponent matches the items against s using the classic two-pointer
// wildcard algorithm with single-star backtracking.
func matchComponent(items []item, s string) bool {
	pi, si := 0, 0
	starPi, starSi := -1, 0
	for si < len(s) {
		if pi < len(items) {
			it := items[pi]
			switch it.kind {
			case itemStar:
				starPi, starSi = pi, si
				pi++
				continue
			case itemAny:
				pi++
				si++
				continue
			case itemLit:
				if it.lit == s[si] {
					pi++
					si++
					continue
				}
			case itemSet:
				if it.set[s[si]] {
					pi++
					si++
					continue
				}
			}
		}
		if starPi < 0 {
			return false
		}
		starSi++
		si = starSi
		pi = starPi + 1
	}
	for pi < len(items) && items[pi].kind == itemStar {
		pi++
	}
	return pi == len(items)
}

// LiteralPrefix returns the longest prefix of pattern that contains no
// wildcard byte, without a trailing "/" (because "dir/**" also matches "dir"
// itself). Every path matching the pattern starts with it, which lets a sorted
// index narrow the candidates.
func LiteralPrefix(pattern string) string {
	if i := strings.IndexAny(pattern, "*?["); i >= 0 {
		pattern = pattern[:i]
	}
	return strings.TrimSuffix(pattern, "/")
}
