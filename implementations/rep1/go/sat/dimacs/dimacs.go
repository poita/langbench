// Package dimacs reads and writes CNF formulas in the DIMACS format and
// formats solver answers in the SAT-competition-like style used by the sat
// command.
package dimacs

import (
	"bytes"
	"fmt"
	"io"
	"strconv"
	"strings"

	"example.com/sat"
)

// Formula is a CNF formula: a list of clauses over variables 1..NumVars.
// A clause is a list of non-zero DIMACS literals.
type Formula struct {
	NumVars int
	Clauses [][]int
}

// Parse reads a DIMACS CNF file. Blank lines and comment lines (first
// non-blank character 'c') are ignored wherever they appear; clauses may span
// lines and share lines. It reports an error if the header is missing, a
// literal is out of range, the clause count differs from the header, or the
// last clause is not terminated by 0.
func Parse(r io.Reader) (*Formula, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	f := &Formula{}
	haveHeader := false
	declared := 0
	var cur []int
	lineNo := 0
	for len(data) > 0 {
		var line []byte
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			line, data = data[:i], data[i+1:]
		} else {
			line, data = data, nil
		}
		lineNo++
		fields := strings.Fields(string(line))
		if len(fields) == 0 || fields[0][0] == 'c' {
			continue
		}
		if fields[0][0] == 'p' {
			if haveHeader {
				return nil, fmt.Errorf("dimacs: line %d: duplicate header", lineNo)
			}
			if len(fields) != 4 || fields[0] != "p" || fields[1] != "cnf" {
				return nil, fmt.Errorf("dimacs: line %d: malformed header", lineNo)
			}
			v, err1 := strconv.Atoi(fields[2])
			c, err2 := strconv.Atoi(fields[3])
			if err1 != nil || err2 != nil || v < 0 || c < 0 {
				return nil, fmt.Errorf("dimacs: line %d: malformed header", lineNo)
			}
			f.NumVars, declared, haveHeader = v, c, true
			continue
		}
		if !haveHeader {
			return nil, fmt.Errorf("dimacs: line %d: clause data before header", lineNo)
		}
		for _, tok := range fields {
			x, err := strconv.Atoi(tok)
			if err != nil {
				return nil, fmt.Errorf("dimacs: line %d: bad token %q", lineNo, tok)
			}
			if x == 0 {
				f.Clauses = append(f.Clauses, cur)
				cur = nil
				continue
			}
			if x > f.NumVars || -x > f.NumVars {
				return nil, fmt.Errorf("dimacs: line %d: literal %d out of range", lineNo, x)
			}
			cur = append(cur, x)
		}
	}
	if !haveHeader {
		return nil, fmt.Errorf("dimacs: missing header")
	}
	if len(cur) > 0 {
		return nil, fmt.Errorf("dimacs: last clause not terminated by 0")
	}
	if len(f.Clauses) != declared {
		return nil, fmt.Errorf("dimacs: header declares %d clauses, found %d", declared, len(f.Clauses))
	}
	return f, nil
}

// Write writes f in DIMACS CNF format.
func (f *Formula) Write(w io.Writer) error {
	var b strings.Builder
	fmt.Fprintf(&b, "p cnf %d %d\n", f.NumVars, len(f.Clauses))
	for _, c := range f.Clauses {
		for _, l := range c {
			b.WriteString(strconv.Itoa(l))
			b.WriteByte(' ')
		}
		b.WriteString("0\n")
	}
	_, err := io.WriteString(w, b.String())
	return err
}

// Solver returns a new solver loaded with the formula.
func (f *Formula) Solver() *sat.Solver {
	s := sat.New()
	s.Reserve(f.NumVars)
	for _, c := range f.Clauses {
		if !s.AddClause(c...) {
			break // already unsatisfiable
		}
	}
	return s
}

// Satisfies reports whether model (element i-1 is the value of variable i)
// satisfies every clause of f.
func (f *Formula) Satisfies(model []bool) bool {
	if len(model) < f.NumVars {
		return false
	}
	for _, c := range f.Clauses {
		ok := false
		for _, l := range c {
			if l > 0 && model[l-1] || l < 0 && !model[-l-1] {
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

// WriteResult writes the answer in the sat command's output format: "UNSAT",
// or "SAT" followed by a line with one literal per variable and a final 0.
func WriteResult(w io.Writer, res sat.Result, model []bool) error {
	if res != sat.Satisfiable {
		_, err := io.WriteString(w, "UNSAT\n")
		return err
	}
	var b strings.Builder
	b.WriteString("SAT\n")
	for i, v := range model {
		if v {
			b.WriteString(strconv.Itoa(i + 1))
		} else {
			b.WriteString(strconv.Itoa(-(i + 1)))
		}
		b.WriteByte(' ')
	}
	b.WriteString("0\n")
	_, err := io.WriteString(w, b.String())
	return err
}
