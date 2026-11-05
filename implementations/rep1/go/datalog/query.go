package datalog

import (
	"bufio"
	"bytes"
	"io"
	"slices"
	"strconv"
)

// Answer is the result of one query: the matching tuples of the queried
// predicate in ascending tuple order.
type Answer struct {
	Pred   Predicate
	Tuples [][]Constant
}

// Query returns the tuples of the model matching q, in ascending tuple order.
// Each full tuple is returned, not just the bindings of the query variables.
func (m *Model) Query(q Query) [][]Constant {
	positions := m.match(q)
	out := make([][]Constant, len(positions))
	rel := m.rels[q.Atom.Pred]
	for i, pos := range positions {
		t := rel.tuple(int(pos))
		row := make([]Constant, len(t))
		for k, id := range t {
			row[k] = m.prog.Consts[id]
		}
		out[i] = row
	}
	return out
}

// Answers answers every query of the program, in program order.
func (m *Model) Answers() []Answer {
	out := make([]Answer, len(m.prog.Queries))
	for i, q := range m.prog.Queries {
		out[i] = Answer{Pred: m.prog.Preds[q.Atom.Pred], Tuples: m.Query(q)}
	}
	return out
}

// Relation returns every tuple of the named predicate in ascending order. An
// unknown predicate is empty.
func (m *Model) Relation(name string, arity int) [][]Constant {
	for id, p := range m.prog.Preds {
		if p.Name == name && p.Arity == arity {
			args := make([]Term, arity)
			for i := range args {
				args[i] = Term{IsVar: true, Index: i}
			}
			return m.Query(Query{Atom: Atom{Pred: id, Args: args}, NumVars: arity})
		}
	}
	return nil
}

// WriteAnswers answers every query and writes the results in the textual
// format: for each query its matching tuples as "p(v1, v2)" lines followed by
// "-- N".
func (m *Model) WriteAnswers(w io.Writer) error {
	bw := bufio.NewWriterSize(w, 1<<16)
	var line []byte
	for _, q := range m.prog.Queries {
		rel := m.rels[q.Atom.Pred]
		name := m.prog.Preds[q.Atom.Pred].Name
		positions := m.match(q)
		for _, pos := range positions {
			line = append(line[:0], name...)
			line = append(line, '(')
			for k, id := range rel.tuple(int(pos)) {
				if k > 0 {
					line = append(line, ',', ' ')
				}
				line = append(line, m.texts[id]...)
			}
			line = append(line, ')', '\n')
			bw.Write(line)
		}
		line = append(line[:0], "-- "...)
		line = strconv.AppendInt(line, int64(len(positions)), 10)
		line = append(line, '\n')
		bw.Write(line)
	}
	return bw.Flush()
}

// match returns the positions of the tuples matching q, sorted by tuple.
func (m *Model) match(q Query) []int32 {
	rel := m.rels[q.Atom.Pred]
	args := q.Atom.Args

	var cols uint64
	var key []int32
	type pair struct{ a, b int }
	var repeats []pair // positions that must hold equal values
	firstPos := map[int]int{}
	for pos, t := range args {
		if !t.IsVar {
			cols |= 1 << pos
			key = append(key, int32(t.Index))
		} else if f, ok := firstPos[t.Index]; ok {
			repeats = append(repeats, pair{f, pos})
		} else {
			firstPos[t.Index] = pos
		}
	}
	// Positions of the constants, in column order, for verification.
	ok := func(t []int32) bool {
		for _, r := range repeats {
			if t[r.a] != t[r.b] {
				return false
			}
		}
		return true
	}

	var out []int32
	if cols != 0 {
		ix := rel.index(cols)
		ix.sync()
		for pos := ix.find(key); pos >= 0; pos = ix.next[pos] {
			if ok(rel.tuple(int(pos))) {
				out = append(out, pos)
			}
		}
	} else {
		for pos := 0; pos < rel.n; pos++ {
			if ok(rel.tuple(pos)) {
				out = append(out, int32(pos))
			}
		}
	}
	slices.SortFunc(out, func(a, b int32) int {
		ta, tb := rel.tuple(int(a)), rel.tuple(int(b))
		for i := range ta {
			if ta[i] != tb[i] {
				if ta[i] < tb[i] {
					return -1
				}
				return 1
			}
		}
		return 0
	})
	return out
}

// Solve parses src, checks and evaluates it, and writes the answers to every
// query to w in the textual format of [Model.WriteAnswers]. Nothing is written
// if parsing or checking fails: the error is a *[SyntaxError], [ErrUnsafe] or
// [ErrNotStratifiable] (possibly wrapped).
func Solve(src []byte, w io.Writer) error {
	prog, err := Parse(src)
	if err != nil {
		return err
	}
	m, err := Evaluate(prog)
	if err != nil {
		return err
	}
	return m.WriteAnswers(w)
}

// SolveString is like [Solve] but takes and returns strings.
func SolveString(src string) (string, error) {
	var buf bytes.Buffer
	if err := Solve([]byte(src), &buf); err != nil {
		return "", err
	}
	return buf.String(), nil
}
