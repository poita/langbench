// Package glob implements Kiln's glob patterns: "/"-separated components with
// "*", "?", "[...]" character classes and the "**" whole-component wildcard.
package glob

import (
	"errors"
	"strings"
)

// ErrBadPattern is returned by Compile for a malformed pattern.
var ErrBadPattern = errors.New("glob: bad pattern")

type itemKind uint8

const (
	itemLit   itemKind = iota
	itemAny            // ?
	itemStar           // *
	itemClass          // [...]
)

type byteRange struct{ lo, hi byte }

type item struct {
	kind   itemKind
	lit    byte
	negate bool
	ranges []byteRange
}

func (it *item) matchByte(b byte) bool {
	switch it.kind {
	case itemLit:
		return it.lit == b
	case itemAny:
		return true
	}
	in := false
	for _, r := range it.ranges {
		if r.lo <= b && b <= r.hi {
			in = true
			break
		}
	}
	return in != it.negate
}

type component struct {
	doubleStar bool
	items      []item
}

// Pattern is a compiled glob pattern.
type Pattern struct {
	comps  []component
	hasDS  bool
	prefix string
}

// Compile parses a pattern. It returns ErrBadPattern if the pattern is empty,
// has a leading or trailing "/", has an empty component, or contains a
// malformed character class.
func Compile(pat string) (*Pattern, error) {
	if pat == "" {
		return nil, ErrBadPattern
	}
	p := &Pattern{}
	for _, c := range strings.Split(pat, "/") {
		if c == "" {
			return nil, ErrBadPattern
		}
		if c == "**" {
			p.comps = append(p.comps, component{doubleStar: true})
			p.hasDS = true
			continue
		}
		items, ok := parseComponent(c)
		if !ok {
			return nil, ErrBadPattern
		}
		p.comps = append(p.comps, component{items: items})
	}
	// The literal prefix is the run of bytes before the first wildcard.
	end := strings.IndexAny(pat, "*?[")
	if end < 0 {
		end = len(pat)
	}
	p.prefix = pat[:end]
	// A trailing run of "**" components may match zero components, so
	// "lib/**" also matches "lib" itself: drop the prefix's trailing slash.
	if strings.HasSuffix(p.prefix, "/") {
		rest := strings.Split(pat[end:], "/")
		allDS := true
		for _, c := range rest {
			allDS = allDS && c == "**"
		}
		if allDS {
			p.prefix = p.prefix[:len(p.prefix)-1]
		}
	}
	return p, nil
}

func parseComponent(c string) ([]item, bool) {
	var items []item
	for i := 0; i < len(c); {
		switch c[i] {
		case '*':
			// Collapse runs of stars: they are equivalent to one.
			if n := len(items); n == 0 || items[n-1].kind != itemStar {
				items = append(items, item{kind: itemStar})
			}
			i++
		case '?':
			items = append(items, item{kind: itemAny})
			i++
		case '[':
			it, n, ok := parseClass(c[i+1:])
			if !ok {
				return nil, false
			}
			items = append(items, it)
			i += 1 + n
		default:
			items = append(items, item{kind: itemLit, lit: c[i]})
			i++
		}
	}
	return items, true
}

// parseClass parses the text following a "[". It returns the class item and
// the number of bytes consumed, including the closing "]".
func parseClass(s string) (item, int, bool) {
	it := item{kind: itemClass}
	i := 0
	if i < len(s) && s[i] == '!' {
		it.negate = true
		i++
	}
	for {
		if i >= len(s) {
			return it, 0, false
		}
		if s[i] == ']' {
			return it, i + 1, len(it.ranges) > 0
		}
		if i+2 < len(s) && s[i+1] == '-' && s[i+2] != ']' {
			if s[i] > s[i+2] {
				return it, 0, false
			}
			it.ranges = append(it.ranges, byteRange{s[i], s[i+2]})
			i += 3
			continue
		}
		it.ranges = append(it.ranges, byteRange{s[i], s[i]})
		i++
	}
}

// LiteralPrefix returns the longest wildcard-free prefix of the pattern. Every
// string the pattern matches begins with it.
func (p *Pattern) LiteralPrefix() string { return p.prefix }

// Match reports whether the pattern matches the whole of s, which is split at
// every "/" into components (empty components are kept).
func (p *Pattern) Match(s string) bool {
	if !p.hasDS {
		// Fast path: component counts must agree.
		pos := 0
		for _, c := range p.comps {
			if pos > len(s) {
				return false
			}
			end := strings.IndexByte(s[pos:], '/')
			var part string
			if end < 0 {
				part = s[pos:]
				pos = len(s) + 1
			} else {
				part = s[pos : pos+end]
				pos += end + 1
			}
			if !matchItems(c.items, part) {
				return false
			}
		}
		return pos == len(s)+1
	}
	cand := strings.Split(s, "/")
	n := len(cand)
	// next[j] = does pattern[i+1:] match cand[j:] ; cur is the row for i.
	next := make([]bool, n+1)
	cur := make([]bool, n+1)
	next[n] = true
	for i := len(p.comps) - 1; i >= 0; i-- {
		c := &p.comps[i]
		for j := n; j >= 0; j-- {
			if c.doubleStar {
				cur[j] = next[j] || (j < n && cur[j+1])
			} else {
				cur[j] = j < n && next[j+1] && matchItems(c.items, cand[j])
			}
		}
		next, cur = cur, next
		// After the swap, next holds row i; the old row is scratch space.
		for j := range cur {
			cur[j] = false
		}
	}
	return next[0]
}

// matchItems matches one pattern component against one candidate component.
func matchItems(items []item, s string) bool {
	pi, si := 0, 0
	starPi, starSi := -1, 0
	for si < len(s) {
		if pi < len(items) {
			it := &items[pi]
			if it.kind == itemStar {
				starPi, starSi = pi, si
				pi++
				continue
			}
			if it.matchByte(s[si]) {
				pi++
				si++
				continue
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
