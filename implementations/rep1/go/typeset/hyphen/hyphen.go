// Package hyphen implements Liang hyphenation over a Codexa pattern set
// (.chp file), with explicit exceptions and left/right minima.
package hyphen

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"typeset/metrics"
)

// Set is a loaded pattern set. Results are memoised per lowercased segment,
// so a Set must not be used from several goroutines at once.
type Set struct {
	Left, Right int
	patterns    map[string][]uint8
	maxKey      int
	exceptions  map[string][]int
	memo        map[string][]int
}

// LoadDir loads data/hyphen/<name>.chp from dataDir.
func LoadDir(dataDir, name string) (*Set, error) {
	b, err := os.ReadFile(filepath.Join(dataDir, "hyphen", name+".chp"))
	if err != nil {
		return nil, err
	}
	return Parse(string(b))
}

// Parse reads the text of a .chp file.
func Parse(text string) (*Set, error) {
	s := &Set{Left: 1, Right: 1, patterns: map[string][]uint8{},
		exceptions: map[string][]int{}, memo: map[string][]int{}}
	for _, line := range strings.Split(text, "\n") {
		fs := metrics.Fields(line)
		if len(fs) == 0 {
			continue
		}
		switch fs[0] {
		case "left", "right":
			if len(fs) < 2 {
				return nil, fmt.Errorf("bad %s record", fs[0])
			}
			n, err := strconv.Atoi(fs[1])
			if err != nil {
				return nil, err
			}
			if fs[0] == "left" {
				s.Left = n
			} else {
				s.Right = n
			}
		case "pattern":
			if len(fs) < 2 {
				return nil, fmt.Errorf("bad pattern record")
			}
			key, vals := splitPattern(fs[1])
			s.patterns[key] = vals
			if len(key) > s.maxKey {
				s.maxKey = len(key)
			}
		case "exception":
			if len(fs) < 2 {
				return nil, fmt.Errorf("bad exception record")
			}
			var word []byte
			var pos []int
			for i := 0; i < len(fs[1]); i++ {
				if fs[1][i] == '-' {
					pos = append(pos, len(word))
				} else {
					word = append(word, fs[1][i])
				}
			}
			s.exceptions[string(word)] = pos
		}
	}
	return s, nil
}

// splitPattern separates a pattern into its key (letters and '.') and its
// len(key)+1 digit values.
func splitPattern(p string) (string, []uint8) {
	var key []byte
	vals := []uint8{0}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if c >= '0' && c <= '9' {
			vals[len(key)] = c - '0'
		} else {
			key = append(key, c)
			vals = append(vals, 0)
		}
	}
	return string(key), vals
}

// Positions returns the permitted breaks of a lowercase all-letter segment as
// the numbers of letters preceding each break, after the left/right minima.
// The result is shared and must not be modified.
func (s *Set) Positions(seg string) []int {
	if r, ok := s.memo[seg]; ok {
		return r
	}
	n := len(seg)
	var raw []int
	if ex, ok := s.exceptions[seg]; ok {
		raw = ex
	} else {
		t := "." + seg + "."
		v := make([]uint8, n+3)
		for i := 0; i < len(t); i++ {
			for j := i + 1; j <= len(t) && j-i <= s.maxKey; j++ {
				if p, ok := s.patterns[t[i:j]]; ok {
					for k, pv := range p {
						if pv > v[i+k] {
							v[i+k] = pv
						}
					}
				}
			}
		}
		for q := 1; q <= n-1; q++ {
			if v[1+q]%2 == 1 {
				raw = append(raw, q)
			}
		}
	}
	var out []int
	for _, q := range raw {
		if q >= s.Left && q <= n-s.Right {
			out = append(out, q)
		}
	}
	s.memo[seg] = out
	return out
}
