// Package glob implements Kiln's glob patterns.
//
// A pattern is split on '/' into components. A component is either "**",
// which matches zero or more whole candidate components, or a sequence of
// items: '*' (any run of non-'/' bytes), '?' (one byte), a character class
// like [a-z] or [!ab], or a literal byte. Patterns are compiled once and can
// then be matched against any number of candidates without allocating.
package glob

import (
	"errors"
	"strings"
)

// ErrBadPattern is returned by Compile for a malformed pattern.
var ErrBadPattern = errors.New("glob: bad pattern")

type itemKind uint8

const (
	itemLit itemKind = iota
	itemAny
	itemStar
	itemClass
)

type item struct {
	kind itemKind
	b    byte
	set  *[256]bool
}

type component struct {
	double bool // exactly "**"
	items  []item
}

// Pattern is a compiled glob pattern.
type Pattern struct {
	comps  []component
	prefix string
}

// Compile parses pattern. It returns ErrBadPattern if the pattern is empty,
// has a leading or trailing '/', has an empty component, or contains a
// malformed character class.
func Compile(pattern string) (*Pattern, error) {
	if pattern == "" {
		return nil, ErrBadPattern
	}
	parts := strings.Split(pattern, "/")
	p := &Pattern{comps: make([]component, len(parts))}
	for i, part := range parts {
		if part == "" {
			return nil, ErrBadPattern
		}
		if part == "**" {
			p.comps[i].double = true
			continue
		}
		items, ok := compileComponent(part)
		if !ok {
			return nil, ErrBadPattern
		}
		p.comps[i].items = items
	}
	// The literal prefix: leading components made only of literal bytes.
	n := 0
	for n < len(parts) && !strings.ContainsAny(parts[n], "*?[") {
		n++
	}
	p.prefix = strings.Join(parts[:n], "/")
	return p, nil
}

func compileComponent(s string) ([]item, bool) {
	var items []item
	for i := 0; i < len(s); {
		switch c := s[i]; c {
		case '*':
			if len(items) == 0 || items[len(items)-1].kind != itemStar {
				items = append(items, item{kind: itemStar})
			}
			i++
		case '?':
			items = append(items, item{kind: itemAny})
			i++
		case '[':
			set, next, ok := compileClass(s, i+1)
			if !ok {
				return nil, false
			}
			items = append(items, item{kind: itemClass, set: set})
			i = next
		default:
			items = append(items, item{kind: itemLit, b: c})
			i++
		}
	}
	return items, true
}

// compileClass parses a character class whose body starts at s[i] (just after
// the '['). It returns the byte set and the index just past the closing ']'.
func compileClass(s string, i int) (*[256]bool, int, bool) {
	neg := false
	if i < len(s) && s[i] == '!' {
		neg = true
		i++
	}
	var set [256]bool
	count := 0
	for {
		if i >= len(s) {
			return nil, 0, false
		}
		if s[i] == ']' {
			if count == 0 {
				return nil, 0, false
			}
			i++
			break
		}
		if i+2 < len(s) && s[i+1] == '-' && s[i+2] != ']' {
			x, y := s[i], s[i+2]
			if x > y {
				return nil, 0, false
			}
			for b := int(x); b <= int(y); b++ {
				set[b] = true
			}
			i += 3
		} else {
			set[s[i]] = true
			i++
		}
		count++
	}
	if neg {
		for b := range set {
			set[b] = !set[b]
		}
	}
	return &set, i, true
}

// Prefix returns the leading literal components of the pattern joined with
// '/'. Every string the pattern matches starts with this prefix; it is empty
// when the first component contains a wildcard. It has no trailing '/'.
func (p *Pattern) Prefix() string { return p.prefix }

// Match reports whether the pattern matches the whole of s, which is split at
// every '/' into components (empty components are kept).
func (p *Pattern) Match(s string) bool {
	comps := p.comps
	pi, off := 0, 0 // off is the start of the current candidate component, or -1
	starPi, starOff := -1, 0
	for {
		if pi < len(comps) && comps[pi].double {
			starPi, starOff = pi, off
			pi++
			continue
		}
		if pi == len(comps) && off < 0 {
			return true
		}
		if pi < len(comps) && off >= 0 {
			end := off
			for end < len(s) && s[end] != '/' {
				end++
			}
			if matchItems(comps[pi].items, s[off:end]) {
				pi++
				if end < len(s) {
					off = end + 1
				} else {
					off = -1
				}
				continue
			}
		}
		// Mismatch: let the most recent "**" swallow one more component.
		if starPi < 0 || starOff < 0 {
			return false
		}
		end := starOff
		for end < len(s) && s[end] != '/' {
			end++
		}
		if end < len(s) {
			starOff = end + 1
		} else {
			starOff = -1
		}
		pi, off = starPi+1, starOff
	}
}

// matchItems matches one component using linear star backtracking.
func matchItems(items []item, s string) bool {
	i, j := 0, 0
	starI, starJ := -1, 0
	for j < len(s) {
		if i < len(items) {
			it := &items[i]
			switch it.kind {
			case itemStar:
				starI, starJ = i, j
				i++
				continue
			case itemAny:
				i++
				j++
				continue
			case itemLit:
				if s[j] == it.b {
					i++
					j++
					continue
				}
			case itemClass:
				if it.set[s[j]] {
					i++
					j++
					continue
				}
			}
		}
		if starI < 0 {
			return false
		}
		starJ++
		i, j = starI+1, starJ
	}
	for i < len(items) && items[i].kind == itemStar {
		i++
	}
	return i == len(items)
}
