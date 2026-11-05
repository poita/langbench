package dimacs

import (
	"errors"
	"fmt"
)

// Formula is a CNF formula. Literals are non-zero DIMACS integers: k means
// variable k is true and -k means it is false, for 1 <= k <= NumVars.
type Formula struct {
	NumVars int
	Clauses [][]int
}

// Errors returned by Parse.
var (
	ErrNoHeader     = errors.New("dimacs: missing 'p cnf' header")
	ErrBadHeader    = errors.New("dimacs: malformed 'p cnf' header")
	ErrDupHeader    = errors.New("dimacs: duplicate header")
	ErrUnterminated = errors.New("dimacs: last clause is not terminated by 0")
	ErrBadLiteral   = errors.New("dimacs: malformed or out-of-range literal")
)

func isBlank(b byte) bool { return b == ' ' || b == '\t' || b == '\r' }

// Parse parses a DIMACS CNF document. The clause count in the header is
// checked against the number of clauses found.
func Parse(data []byte) (*Formula, error) {
	f := &Formula{}
	haveHeader := false
	declared := 0

	var lits []int // backing store for all clauses
	var ends []int // end offsets of each clause in lits
	start := 0     // start of the clause under construction in lits

	n := len(data)
	i := 0
	for i < n {
		// Find the extent of this line.
		j := i
		for j < n && data[j] != '\n' {
			j++
		}
		line := data[i:j]
		i = j + 1

		p := 0
		for p < len(line) && isBlank(line[p]) {
			p++
		}
		if p == len(line) {
			continue
		}
		switch line[p] {
		case 'c':
			continue
		case 'p':
			if haveHeader {
				return nil, ErrDupHeader
			}
			v, c, ok := parseHeader(line[p:])
			if !ok {
				return nil, ErrBadHeader
			}
			f.NumVars, declared, haveHeader = v, c, true
			continue
		}
		if !haveHeader {
			return nil, ErrNoHeader
		}
		// Clause data: integers separated by blanks.
		for p < len(line) {
			for p < len(line) && isBlank(line[p]) {
				p++
			}
			if p == len(line) {
				break
			}
			neg := false
			if line[p] == '-' {
				neg = true
				p++
			}
			if p == len(line) || line[p] < '0' || line[p] > '9' {
				return nil, ErrBadLiteral
			}
			x := 0
			for p < len(line) && line[p] >= '0' && line[p] <= '9' {
				x = x*10 + int(line[p]-'0')
				if x > f.NumVars {
					return nil, ErrBadLiteral
				}
				p++
			}
			if p < len(line) && !isBlank(line[p]) {
				return nil, ErrBadLiteral
			}
			if x == 0 {
				if neg {
					return nil, ErrBadLiteral
				}
				lits = append(lits, 0) // terminator, trimmed below
				ends = append(ends, len(lits)-1)
				start = len(lits)
				continue
			}
			if neg {
				x = -x
			}
			lits = append(lits, x)
		}
	}
	if !haveHeader {
		return nil, ErrNoHeader
	}
	if start != len(lits) {
		return nil, ErrUnterminated
	}
	if len(ends) != declared {
		return nil, fmt.Errorf("dimacs: header declares %d clauses, found %d", declared, len(ends))
	}
	f.Clauses = make([][]int, len(ends))
	s := 0
	for k, e := range ends {
		f.Clauses[k] = lits[s:e:e]
		s = e + 1 // skip the 0 terminator
	}
	return f, nil
}

// parseHeader parses "p cnf V C".
func parseHeader(line []byte) (v, c int, ok bool) {
	var tok [4][]byte
	nt := 0
	p := 0
	for p < len(line) {
		for p < len(line) && isBlank(line[p]) {
			p++
		}
		if p == len(line) {
			break
		}
		q := p
		for q < len(line) && !isBlank(line[q]) {
			q++
		}
		if nt == 4 {
			return 0, 0, false
		}
		tok[nt] = line[p:q]
		nt++
		p = q
	}
	if nt != 4 || string(tok[0]) != "p" || string(tok[1]) != "cnf" {
		return 0, 0, false
	}
	var okv, okc bool
	v, okv = atoi(tok[2])
	c, okc = atoi(tok[3])
	return v, c, okv && okc
}

func atoi(b []byte) (int, bool) {
	if len(b) == 0 || len(b) > 12 {
		return 0, false
	}
	x := 0
	for _, ch := range b {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		x = x*10 + int(ch-'0')
	}
	return x, true
}
