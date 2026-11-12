// Package hyphen implements Liang's hyphenation algorithm over Codexa
// pattern (.chp) files.
package hyphen

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Patterns is a loaded pattern set.
type Patterns struct {
	// Left and Right are the minimum letters before the first and after
	// the last break.
	Left, Right int

	pats   map[string][]uint8
	exc    map[string][]int
	maxKey int
}

// Parse reads a .chp file.
func Parse(r io.Reader) (*Patterns, error) {
	p := &Patterns{pats: map[string][]uint8{}, exc: map[string][]int{}}
	sc := bufio.NewScanner(r)
	n := 0
	for sc.Scan() {
		n++
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "chp":
		case "left", "right":
			if len(fields) != 2 {
				return nil, fmt.Errorf("line %d: bad %s record", n, fields[0])
			}
			v, err := strconv.Atoi(fields[1])
			if err != nil {
				return nil, fmt.Errorf("line %d: %v", n, err)
			}
			if fields[0] == "left" {
				p.Left = v
			} else {
				p.Right = v
			}
		case "pattern":
			if len(fields) != 2 {
				return nil, fmt.Errorf("line %d: bad pattern record", n)
			}
			key, vals := parsePattern(fields[1])
			p.pats[key] = vals
			if len(key) > p.maxKey {
				p.maxKey = len(key)
			}
		case "exception":
			if len(fields) != 2 {
				return nil, fmt.Errorf("line %d: bad exception record", n)
			}
			var key []byte
			var pos []int
			for i := 0; i < len(fields[1]); i++ {
				if fields[1][i] == '-' {
					pos = append(pos, len(key))
				} else {
					key = append(key, fields[1][i])
				}
			}
			p.exc[string(key)] = pos
		default:
			return nil, fmt.Errorf("line %d: unknown record %q", n, fields[0])
		}
	}
	return p, sc.Err()
}

// parsePattern splits "a1b" into the key "ab" and the values [0,1,0].
func parsePattern(s string) (string, []uint8) {
	var key []byte
	vals := []uint8{0}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= '0' && c <= '9' {
			vals[len(vals)-1] = c - '0'
			continue
		}
		key = append(key, c)
		vals = append(vals, 0)
	}
	return string(key), vals
}

// Points returns the permitted break positions of a lowercase segment of
// letters: q means "after q letters". The left/right minima are applied.
func (p *Patterns) Points(seg string) []int {
	n := len(seg)
	var cand []int
	if pos, ok := p.exc[seg]; ok {
		cand = pos
	} else {
		t := "." + seg + "."
		v := make([]uint8, n+3)
		for i := 0; i < len(t); i++ {
			for j := i + 1; j <= len(t) && j-i <= p.maxKey; j++ {
				if vals, ok := p.pats[t[i:j]]; ok {
					for k, x := range vals {
						if x > v[i+k] {
							v[i+k] = x
						}
					}
				}
			}
		}
		for q := 1; q <= n-1; q++ {
			if v[1+q]%2 == 1 {
				cand = append(cand, q)
			}
		}
	}
	var out []int
	for _, q := range cand {
		if q >= p.Left && q <= n-p.Right {
			out = append(out, q)
		}
	}
	return out
}
