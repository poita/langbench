// Package dimacs reads CNF formulas in the DIMACS format and writes
// solver results in the format used by the sat command.
//
// Literals are non-zero integers: k means "variable k is true" and -k means
// "variable k is false", for variables numbered from 1.
package dimacs

import (
	"errors"
	"fmt"
)

// Formula is a CNF formula.
type Formula struct {
	// NumVars is the variable count declared by the "p cnf V C" header.
	NumVars int
	// Clauses holds the clauses in input order. Each clause is a list of
	// non-zero literals; it may be empty, and may repeat literals or contain
	// complementary ones. All clauses share one backing array.
	Clauses [][]int
}

// ErrSyntax is wrapped by every error returned from Parse.
var ErrSyntax = errors.New("dimacs: syntax error")

func syntaxErr(line int, format string, args ...any) error {
	return fmt.Errorf("%w: line %d: %s", ErrSyntax, line, fmt.Sprintf(format, args...))
}

func isBlank(b byte) bool { return b == ' ' || b == '\t' || b == '\r' }

// Parse parses a DIMACS CNF document.
//
// Blank lines and comment lines (first non-blank character 'c') are ignored
// anywhere. Exactly one "p cnf V C" header must precede the clause data.
// Clauses are runs of integers terminated by 0 and may span lines or share
// a line. Parse reports an error if a literal is out of range, a clause is
// unterminated, or the number of clauses differs from the header.
func Parse(data []byte) (*Formula, error) {
	f := &Formula{}
	var (
		haveHeader bool
		wantClause int
		lits       []int // all literals, clause bodies back to back
		ends       []int // end offset in lits of every clause
		start      int   // start offset of the clause being read
		lineNo     int
	)
	n := len(data)
	for pos := 0; pos < n; {
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
				return nil, syntaxErr(lineNo, "duplicate header")
			}
			v, c, err := parseHeader(line[i:])
			if err != nil {
				return nil, syntaxErr(lineNo, "%v", err)
			}
			haveHeader = true
			f.NumVars, wantClause = v, c
			continue
		}
		if !haveHeader {
			return nil, syntaxErr(lineNo, "clause data before header")
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
				return nil, syntaxErr(lineNo, "invalid token")
			}
			x := 0
			for i < len(line) && line[i] >= '0' && line[i] <= '9' {
				x = x*10 + int(line[i]-'0')
				if x > 1<<40 {
					return nil, syntaxErr(lineNo, "number too large")
				}
				i++
			}
			if i < len(line) && !isBlank(line[i]) {
				return nil, syntaxErr(lineNo, "invalid token")
			}
			if x == 0 {
				ends = append(ends, len(lits))
				start = len(lits)
				continue
			}
			if x > f.NumVars {
				return nil, syntaxErr(lineNo, "literal %d out of range (V=%d)", x, f.NumVars)
			}
			if neg {
				x = -x
			}
			lits = append(lits, x)
		}
	}
	if !haveHeader {
		return nil, fmt.Errorf("%w: missing header", ErrSyntax)
	}
	if start != len(lits) {
		return nil, fmt.Errorf("%w: last clause is not terminated by 0", ErrSyntax)
	}
	if len(ends) != wantClause {
		return nil, fmt.Errorf("%w: header declares %d clauses, found %d", ErrSyntax, wantClause, len(ends))
	}
	f.Clauses = make([][]int, len(ends))
	s := 0
	for k, e := range ends {
		f.Clauses[k] = lits[s:e:e]
		s = e
	}
	return f, nil
}

func parseHeader(line []byte) (vars, clauses int, err error) {
	var tok [4][]byte
	cnt := 0
	for i := 0; i < len(line); {
		if isBlank(line[i]) {
			i++
			continue
		}
		j := i
		for j < len(line) && !isBlank(line[j]) {
			j++
		}
		if cnt == 4 {
			return 0, 0, errors.New("malformed header")
		}
		tok[cnt] = line[i:j]
		cnt++
		i = j
	}
	if cnt != 4 || string(tok[0]) != "p" || string(tok[1]) != "cnf" {
		return 0, 0, errors.New("malformed header")
	}
	if vars, err = atoi(tok[2]); err != nil {
		return 0, 0, err
	}
	if clauses, err = atoi(tok[3]); err != nil {
		return 0, 0, err
	}
	return vars, clauses, nil
}

func atoi(b []byte) (int, error) {
	if len(b) == 0 || len(b) > 12 {
		return 0, errors.New("malformed header number")
	}
	x := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, errors.New("malformed header number")
		}
		x = x*10 + int(c-'0')
	}
	return x, nil
}
