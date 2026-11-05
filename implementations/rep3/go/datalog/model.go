package datalog

import (
	"bufio"
	"io"
	"slices"

	"github.com/example/datalog/internal/store"
)

// Model is the perfect model of a solved program.
type Model struct {
	prog *Program
	rels []*store.Relation
}

// Answer is the result of one query: the matching tuples of the predicate in
// ascending tuple order.
type Answer struct {
	Pred   string
	Tuples [][]Value
}

// Answers evaluates the program's queries, in program order.
func (m *Model) Answers() []Answer {
	out := make([]Answer, len(m.prog.queries))
	for i := range m.prog.queries {
		out[i] = m.answer(&m.prog.queries[i])
	}
	return out
}

// Relation returns all tuples of the predicate name/arity in ascending tuple
// order. An unknown predicate is empty.
func (m *Model) Relation(name string, arity int) [][]Value {
	for id, pi := range m.prog.preds {
		if pi.name == name && pi.arity == arity {
			rel := m.rels[id]
			rows := make([][]int32, rel.Len())
			for i := range rows {
				rows[i] = rel.Tuple(i)
			}
			return m.values(rows)
		}
	}
	return nil
}

func (m *Model) values(rows [][]int32) [][]Value {
	slices.SortFunc(rows, slices.Compare[[]int32])
	out := make([][]Value, len(rows))
	for i, row := range rows {
		t := make([]Value, len(row))
		for j, id := range row {
			t[j] = m.prog.consts[id]
		}
		out[i] = t
	}
	return out
}

// answer matches a query against its relation. Constant positions select
// through a hash index; repeated variables are checked on the candidates.
func (m *Model) answer(q *query) Answer {
	rel := m.rels[q.atom.pred]
	var cols []int
	var key []int32
	var eqs [][2]int
	firstPos := make(map[int32]int)
	for i, t := range q.atom.args {
		switch {
		case !t.isVar:
			cols = append(cols, i)
			key = append(key, t.id)
		default:
			if fp, ok := firstPos[t.id]; ok {
				eqs = append(eqs, [2]int{i, fp})
			} else {
				firstPos[t.id] = i
			}
		}
	}
	var rows [][]int32
	accept := func(row []int32) {
		for _, e := range eqs {
			if row[e[0]] != row[e[1]] {
				return
			}
		}
		rows = append(rows, row)
	}
	if len(cols) > 0 {
		ix := rel.Index(cols)
		ix.Update()
		for pos := ix.First(key); pos >= 0; pos = ix.Next(pos) {
			accept(rel.Tuple(int(pos)))
		}
	} else {
		for i := 0; i < rel.Len(); i++ {
			accept(rel.Tuple(i))
		}
	}
	return Answer{Pred: m.prog.preds[q.atom.pred].name, Tuples: m.values(rows)}
}

// WriteAnswers writes answers in the canonical text format: for each answer,
// one line "pred(v1, v2, ...)" per tuple followed by "-- N", where N is the
// number of tuples.
func WriteAnswers(w io.Writer, answers []Answer) error {
	bw := bufio.NewWriter(w)
	var line []byte
	for _, a := range answers {
		for _, t := range a.Tuples {
			line = append(line[:0], a.Pred...)
			line = append(line, '(')
			for i, v := range t {
				if i > 0 {
					line = append(line, ", "...)
				}
				line = append(line, v.String()...)
			}
			line = append(line, ')', '\n')
			bw.Write(line)
		}
		bw.WriteString("-- ")
		bw.WriteString(itoa(len(a.Tuples)))
		bw.WriteByte('\n')
	}
	return bw.Flush()
}

func itoa(n int) string { return Int(int64(n)).String() }
