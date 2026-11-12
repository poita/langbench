// Package dimacs reads formulas in DIMACS CNF format and writes solver
// results in the "SAT / assignment line" format used by the sat command.
package dimacs

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"strconv"

	"example.com/sat"
)

// CNF is a parsed DIMACS formula. Literals are non-zero DIMACS integers.
type CNF struct {
	NumVars int
	Clauses [][]int
}

// Parse reads a DIMACS CNF formula.
//
// Lines are classified by their first non-blank character: blank lines and
// comment lines (starting with 'c') are ignored wherever they appear, the
// single "p cnf V C" header must precede the clause data, and everything else
// is clause data in which integers form 0-terminated clauses that may span
// lines or share a line. Parse reports an error if the header is missing or
// malformed, a literal is out of range, a clause is unterminated, or the
// number of clauses differs from the header.
func Parse(r io.Reader) (*CNF, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	var (
		f        CNF
		declared = -1
		cur      []int
		lineNo   int
	)
	for len(data) > 0 {
		line := data
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			line, data = data[:i], data[i+1:]
		} else {
			data = nil
		}
		lineNo++
		line = bytes.Trim(line, " \t\r")
		if len(line) == 0 || line[0] == 'c' {
			continue
		}
		fields := bytes.Fields(line)
		if line[0] == 'p' {
			if declared >= 0 {
				return nil, fmt.Errorf("dimacs: line %d: duplicate header", lineNo)
			}
			if len(fields) != 4 || string(fields[0]) != "p" || string(fields[1]) != "cnf" {
				return nil, fmt.Errorf("dimacs: line %d: malformed header", lineNo)
			}
			v, err1 := strconv.Atoi(string(fields[2]))
			c, err2 := strconv.Atoi(string(fields[3]))
			if err1 != nil || err2 != nil || v < 0 || c < 0 {
				return nil, fmt.Errorf("dimacs: line %d: malformed header", lineNo)
			}
			f.NumVars, declared = v, c
			f.Clauses = make([][]int, 0, min(c, 1<<20))
			continue
		}
		if declared < 0 {
			return nil, fmt.Errorf("dimacs: line %d: clause data before header", lineNo)
		}
		for _, tok := range fields {
			k, err := strconv.Atoi(string(tok))
			if err != nil {
				return nil, fmt.Errorf("dimacs: line %d: bad literal %q", lineNo, tok)
			}
			if k == 0 {
				f.Clauses = append(f.Clauses, cur)
				cur = nil
				continue
			}
			if k > f.NumVars || -k > f.NumVars {
				return nil, fmt.Errorf("dimacs: line %d: literal %d out of range", lineNo, k)
			}
			cur = append(cur, k)
		}
	}
	if declared < 0 {
		return nil, fmt.Errorf("dimacs: missing header")
	}
	if len(cur) > 0 {
		return nil, fmt.Errorf("dimacs: last clause is not terminated by 0")
	}
	if len(f.Clauses) != declared {
		return nil, fmt.Errorf("dimacs: header declares %d clauses, found %d", declared, len(f.Clauses))
	}
	return &f, nil
}

// Solver returns a new solver loaded with the formula's variables and
// clauses. Every variable 1..NumVars exists in the solver, whether or not it
// occurs in a clause.
func (f *CNF) Solver() *sat.Solver {
	s := sat.NewSolver()
	for i := 0; i < f.NumVars; i++ {
		s.NewVar()
	}
	lits := make([]sat.Lit, 0, 8)
	for _, c := range f.Clauses {
		lits = lits[:0]
		for _, k := range c {
			lits = append(lits, sat.FromDIMACS(k))
		}
		s.AddClause(lits...)
	}
	return s
}

// WriteResult writes "UNSAT\n" for an unsatisfiable result, and for a
// satisfiable one "SAT\n" followed by a line with one literal per variable of
// model (variable i+1 is true if model[i]) and a terminating 0.
func WriteResult(w io.Writer, status sat.Status, model []bool) error {
	bw := bufio.NewWriter(w)
	if status != sat.Satisfiable {
		bw.WriteString("UNSAT\n")
		return bw.Flush()
	}
	bw.WriteString("SAT\n")
	buf := make([]byte, 0, 16)
	for i, val := range model {
		k := i + 1
		if !val {
			k = -k
		}
		bw.Write(strconv.AppendInt(buf[:0], int64(k), 10))
		bw.WriteByte(' ')
	}
	bw.WriteString("0\n")
	return bw.Flush()
}
