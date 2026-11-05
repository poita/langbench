// Package glob implements Kiln's glob patterns: "/"-separated components
// where "**" matches zero or more whole components and other components
// are made of literal bytes, "?", "*" and "[...]" character classes.
package glob

import "strings"

type itemKind uint8

const (
	lit itemKind = iota
	any1
	star
	class
)

type item struct {
	kind   itemKind
	b      byte
	neg    bool
	ranges []byteRange
}

type byteRange struct{ lo, hi byte }

type component struct {
	doubleStar bool
	items      []item
}

// Pattern is a compiled glob pattern. A Pattern keeps scratch storage and so
// must not be used from several goroutines at once.
type Pattern struct {
	comps   []component
	prefix  string
	scratch []int32
}

// Compile compiles pattern. It reports false if the pattern is malformed:
// empty, with a leading or trailing "/", with an empty component, or with a
// malformed character class.
func Compile(pattern string) (*Pattern, bool) {
	if pattern == "" {
		return nil, false
	}
	p := &Pattern{}
	start := 0
	literal := true // still inside the leading run of metacharacter-free components
	for i := 0; i <= len(pattern); i++ {
		if i < len(pattern) && pattern[i] != '/' {
			continue
		}
		if i == start {
			return nil, false
		}
		c, ok := compileComponent(pattern[start:i])
		if !ok {
			return nil, false
		}
		p.comps = append(p.comps, c)
		if literal && !strings.ContainsAny(pattern[start:i], "*?[") {
			p.prefix = pattern[:i]
		} else {
			literal = false
		}
		start = i + 1
	}
	return p, true
}

func compileComponent(s string) (component, bool) {
	if s == "**" {
		return component{doubleStar: true}, true
	}
	var items []item
	for i := 0; i < len(s); {
		switch c := s[i]; c {
		case '*':
			// Collapse runs of '*'; they are equivalent to one.
			if len(items) == 0 || items[len(items)-1].kind != star {
				items = append(items, item{kind: star})
			}
			i++
		case '?':
			items = append(items, item{kind: any1})
			i++
		case '[':
			it, n, ok := compileClass(s[i+1:])
			if !ok {
				return component{}, false
			}
			items = append(items, it)
			i += 1 + n
		default:
			items = append(items, item{kind: lit, b: c})
			i++
		}
	}
	return component{items: items}, true
}

// compileClass parses the inside of a class, starting just after "[". It
// returns the item and the number of bytes consumed including the closing "]".
func compileClass(s string) (item, int, bool) {
	it := item{kind: class}
	i := 0
	if i < len(s) && s[i] == '!' {
		it.neg = true
		i++
	}
	for {
		if i >= len(s) {
			return it, 0, false
		}
		if s[i] == ']' {
			if len(it.ranges) == 0 {
				return it, 0, false
			}
			return it, i + 1, true
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

// LiteralPrefix returns the leading pattern components that contain no
// metacharacters, joined with "/" (no trailing slash). Every path the pattern
// matches begins with this byte prefix, so it can narrow a sorted-path search.
func (p *Pattern) LiteralPrefix() string { return p.prefix }

// Match reports whether the whole of s matches the pattern. s is split at
// every "/" into components; empty components are kept.
func (p *Pattern) Match(s string) bool {
	// Component boundaries: scratch[2k], scratch[2k+1] = start,end of comp k.
	b := p.scratch[:0]
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			b = append(b, int32(start), int32(i))
			start = i + 1
		}
	}
	b = append(b, int32(start), int32(len(s)))
	p.scratch = b
	nc := len(b) / 2

	pi, ci := 0, 0
	starPi, starCi := -1, 0
	for ci < nc {
		if pi < len(p.comps) && p.comps[pi].doubleStar {
			starPi, starCi = pi, ci
			pi++
			continue
		}
		if pi < len(p.comps) && matchComponent(p.comps[pi].items, s[b[2*ci]:b[2*ci+1]]) {
			pi++
			ci++
			continue
		}
		if starPi >= 0 {
			starCi++
			ci = starCi
			pi = starPi + 1
			continue
		}
		return false
	}
	for pi < len(p.comps) && p.comps[pi].doubleStar {
		pi++
	}
	return pi == len(p.comps)
}

func matchComponent(items []item, s string) bool {
	ii, si := 0, 0
	starIi, starSi := -1, 0
	for si < len(s) {
		if ii < len(items) {
			it := &items[ii]
			switch it.kind {
			case star:
				starIi, starSi = ii, si
				ii++
				continue
			case any1:
				ii++
				si++
				continue
			case lit:
				if it.b == s[si] {
					ii++
					si++
					continue
				}
			case class:
				if it.matches(s[si]) {
					ii++
					si++
					continue
				}
			}
		}
		if starIi >= 0 {
			starSi++
			si = starSi
			ii = starIi + 1
			continue
		}
		return false
	}
	for ii < len(items) && items[ii].kind == star {
		ii++
	}
	return ii == len(items)
}

func (it *item) matches(c byte) bool {
	in := false
	for _, r := range it.ranges {
		if c >= r.lo && c <= r.hi {
			in = true
			break
		}
	}
	return in != it.neg
}
