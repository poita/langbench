package sat

import (
	"errors"
	"fmt"
	"io"
)

// CNF is a formula in conjunctive normal form over variables 1..NumVars.
// Each clause is a slice of non-zero DIMACS literals. Clauses may be empty,
// contain repeated literals, or contain a literal together with its negation.
type CNF struct {
	NumVars int
	Clauses [][]int
}

// ParseDIMACS reads a formula in DIMACS CNF format.
//
// Blank lines and comment lines (first non-blank character 'c') are ignored
// anywhere. A single "p cnf V C" header must precede the clause data. Clauses
// are zero-terminated and may span lines or share a line. An error is
// returned for a missing or duplicate header, malformed integers, literals
// outside 1..V, a clause count that differs from the header, or input that
// ends in the middle of a clause.
func ParseDIMACS(r io.Reader) (*CNF, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return ParseDIMACSBytes(data)
}

// ParseDIMACSBytes is like ParseDIMACS but parses an in-memory buffer.
func ParseDIMACSBytes(data []byte) (*CNF, error) {
	cnf := &CNF{}
	haveHeader := false
	wantClauses := 0
	var lits []int // flat literal storage; clauses are sub-slices of it
	start := 0     // start of the clause currently being read, in lits
	type span struct{ lo, hi int }
	var spans []span

	n := len(data)
	pos := 0
	lineNo := 0
	for pos < n {
		lineNo++
		end := pos
		for end < n && data[end] != '\n' {
			end++
		}
		line := data[pos:end]
		pos = end + 1

		i := 0
		for i < len(line) && isBlank(line[i]) {
			i++
		}
		if i == len(line) || line[i] == 'c' {
			continue
		}
		if line[i] == 'p' {
			if haveHeader {
				return nil, fmt.Errorf("line %d: duplicate header", lineNo)
			}
			var v, c int
			if _, err := fmt.Sscanf(string(line[i:]), "p cnf %d %d", &v, &c); err != nil || v < 0 || c < 0 {
				return nil, fmt.Errorf("line %d: malformed header", lineNo)
			}
			cnf.NumVars, wantClauses, haveHeader = v, c, true
			continue
		}
		if !haveHeader {
			return nil, fmt.Errorf("line %d: clause data before header", lineNo)
		}
		for i < len(line) {
			if isBlank(line[i]) {
				i++
				continue
			}
			neg := false
			if line[i] == '-' {
				neg = true
				i++
			}
			if i >= len(line) || line[i] < '0' || line[i] > '9' {
				return nil, fmt.Errorf("line %d: malformed integer", lineNo)
			}
			x := 0
			for i < len(line) && line[i] >= '0' && line[i] <= '9' {
				x = x*10 + int(line[i]-'0')
				if x > 1<<40 {
					return nil, fmt.Errorf("line %d: integer too large", lineNo)
				}
				i++
			}
			if i < len(line) && !isBlank(line[i]) {
				return nil, fmt.Errorf("line %d: malformed integer", lineNo)
			}
			if x == 0 {
				spans = append(spans, span{start, len(lits)})
				start = len(lits)
				continue
			}
			if x > cnf.NumVars {
				return nil, fmt.Errorf("line %d: literal %d out of range", lineNo, x)
			}
			if neg {
				x = -x
			}
			lits = append(lits, x)
		}
	}
	if !haveHeader {
		return nil, errors.New("missing header")
	}
	if start != len(lits) {
		return nil, errors.New("input ends in the middle of a clause")
	}
	if len(spans) != wantClauses {
		return nil, fmt.Errorf("header declares %d clauses, found %d", wantClauses, len(spans))
	}
	cnf.Clauses = make([][]int, len(spans))
	for i, s := range spans {
		cnf.Clauses[i] = lits[s.lo:s.hi:s.hi]
	}
	return cnf, nil
}

func isBlank(b byte) bool { return b == ' ' || b == '\t' }

// Satisfies reports whether the assignment model (model[i] is the value of
// variable i+1) satisfies every clause of the formula.
func (f *CNF) Satisfies(model []bool) bool {
	if len(model) < f.NumVars {
		return false
	}
	for _, c := range f.Clauses {
		ok := false
		for _, l := range c {
			if (l > 0) == model[abs(l)-1] {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	return true
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// Solve decides satisfiability of the formula with a fresh Solver. When the
// status is Satisfiable the returned model has NumVars entries.
func Solve(f *CNF) (Status, []bool) {
	s := NewSolver(f.NumVars)
	for _, c := range f.Clauses {
		if !s.AddClause(c...) {
			break
		}
	}
	st := s.Solve()
	if st == Satisfiable {
		return st, s.Model()
	}
	return st, nil
}
