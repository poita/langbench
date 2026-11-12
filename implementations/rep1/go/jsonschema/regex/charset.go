package regex

import "sort"

const maxRune = 0x10FFFF

// charset is a set of code points stored as sorted, non-overlapping, non-adjacent
// inclusive ranges [lo0, hi0, lo1, hi1, ...].
type charset struct {
	r []rune
}

func (c *charset) add(lo, hi rune) { c.r = append(c.r, lo, hi) }

func (c *charset) addSet(o *charset) { c.r = append(c.r, o.r...) }

// normalize sorts and merges the ranges.
func (c *charset) normalize() *charset {
	n := len(c.r) / 2
	if n <= 1 {
		return c
	}
	type rng struct{ lo, hi rune }
	rs := make([]rng, n)
	for i := range rs {
		rs[i] = rng{c.r[2*i], c.r[2*i+1]}
	}
	sort.Slice(rs, func(i, j int) bool { return rs[i].lo < rs[j].lo })
	out := c.r[:0]
	cur := rs[0]
	for _, x := range rs[1:] {
		if x.lo <= cur.hi+1 {
			if x.hi > cur.hi {
				cur.hi = x.hi
			}
			continue
		}
		out = append(out, cur.lo, cur.hi)
		cur = x
	}
	out = append(out, cur.lo, cur.hi)
	c.r = out
	return c
}

// negate returns the complement of c over all code points. c must be normalised.
func (c *charset) negate() *charset {
	out := &charset{}
	next := rune(0)
	for i := 0; i < len(c.r); i += 2 {
		if c.r[i] > next {
			out.add(next, c.r[i]-1)
		}
		next = c.r[i+1] + 1
	}
	if next <= maxRune {
		out.add(next, maxRune)
	}
	return out
}

func (c *charset) contains(r rune) bool {
	rs := c.r
	if len(rs) <= 8 {
		for i := 0; i < len(rs); i += 2 {
			if r >= rs[i] && r <= rs[i+1] {
				return true
			}
		}
		return false
	}
	// Binary search for the first range whose hi >= r.
	lo, hi := 0, len(rs)/2
	for lo < hi {
		m := (lo + hi) / 2
		if rs[2*m+1] < r {
			lo = m + 1
		} else {
			hi = m
		}
	}
	return lo < len(rs)/2 && r >= rs[2*lo]
}

var (
	digitSet = (&charset{r: []rune{'0', '9'}}).normalize()
	wordSet  = (&charset{r: []rune{'0', '9', 'A', 'Z', '_', '_', 'a', 'z'}}).normalize()
	spaceSet = (&charset{r: []rune{
		0x09, 0x0D, 0x20, 0x20, 0xA0, 0xA0, 0x1680, 0x1680, 0x2000, 0x200A,
		0x2028, 0x2029, 0x202F, 0x202F, 0x205F, 0x205F, 0x3000, 0x3000, 0xFEFF, 0xFEFF,
	}}).normalize()
	dotSet = (&charset{r: []rune{'\n', '\n', '\r', '\r', 0x2028, 0x2029}}).normalize().negate()
)

func isWordRune(r rune) bool {
	return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_'
}
