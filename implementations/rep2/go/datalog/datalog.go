// Package datalog is a Datalog engine with stratified negation.
//
// A program is a sequence of facts, rules and queries:
//
//	edge(1, 2). edge(2, 3).
//	path(X, Y) :- edge(X, Y).
//	path(X, Z) :- edge(X, Y), path(Y, Z).
//	?- path(1, X).
//
// The pipeline has four stages, each in its own package:
//
//   - package parser reads the text into an ast.Program, interning constants
//     in their total order (integers, then identifiers);
//   - package analysis checks rule safety and stratifiability;
//   - package engine computes the perfect model by semi-naive evaluation;
//   - this package ties them together and renders query answers.
//
// Most callers only need [Run] (text in, text out) or [Parse], [Program.Eval]
// and [Model.Answer].
package datalog

import (
	"bytes"
	"errors"
	"strings"

	"datalog/analysis"
	"datalog/ast"
	"datalog/engine"
	"datalog/parser"
)

// Errors returned by Check, Eval and Run (use errors.Is).
var (
	ErrUnsafe          = analysis.ErrUnsafe
	ErrNotStratifiable = analysis.ErrNotStratifiable
)

// SyntaxError reports malformed program text.
type SyntaxError = parser.SyntaxError

// Re-exported syntax tree types.
type (
	Atom     = ast.Atom
	Constant = ast.Constant
)

// Program is a parsed Datalog program.
type Program struct {
	*ast.Program
}

// Parse parses program text. It does not check safety or stratification.
func Parse(src []byte) (*Program, error) {
	p, err := parser.Parse(src)
	if err != nil {
		return nil, err
	}
	return &Program{p}, nil
}

// Check verifies that every rule is safe and that the program is
// stratifiable. It returns an error wrapping ErrUnsafe or ErrNotStratifiable.
func (p *Program) Check() error {
	_, err := p.check()
	return err
}

func (p *Program) check() (*analysis.Stratification, error) {
	if err := analysis.CheckSafety(p.Program); err != nil {
		return nil, err
	}
	return analysis.Stratify(p.Program)
}

// Eval checks the program and computes its stratified model.
func (p *Program) Eval() (*Model, error) {
	s, err := p.check()
	if err != nil {
		return nil, err
	}
	return &Model{prog: p.Program, db: engine.Evaluate(p.Program, s)}, nil
}

// Model is the computed model of a program.
type Model struct {
	prog *ast.Program
	db   *engine.Database
}

// Result is the answer to one query: every matching tuple, in ascending
// tuple order.
type Result struct {
	Pred   string       // predicate name
	Tuples [][]Constant // matching tuples, sorted
}

// Query returns the tuples matching the i-th query of the program.
func (m *Model) Query(i int) Result { return m.Answer(m.prog.Queries[i]) }

// Queries returns the number of queries in the program.
func (m *Model) Queries() int { return len(m.prog.Queries) }

// Answer matches an arbitrary atom (whose ids refer to the program's
// predicate and constant tables) against the model.
func (m *Model) Answer(q Atom) Result {
	rows := m.db.Match(q)
	res := Result{Pred: m.prog.Preds[q.Pred].Name, Tuples: make([][]Constant, len(rows))}
	for i, row := range rows {
		t := make([]Constant, len(row))
		for j, id := range row {
			t[j] = m.prog.Consts[id]
		}
		res.Tuples[i] = t
	}
	return res
}

// Facts returns all tuples of the predicate name/arity in ascending order,
// or nil if the program never mentions that predicate.
func (m *Model) Facts(name string, arity int) [][]Constant {
	for id, p := range m.prog.Preds {
		if p.Name == name && p.Arity == arity {
			args := make([]ast.Term, arity)
			for i := range args {
				args[i] = ast.Term{IsVar: true, ID: i}
			}
			return m.Answer(Atom{Pred: id, Args: args}).Tuples
		}
	}
	return nil
}

// Format renders a result as one "name(v1, v2)" line per tuple followed by
// "-- N".
func (r Result) Format() string {
	var b strings.Builder
	r.writeTo(&b)
	return b.String()
}

func (r Result) writeTo(b *strings.Builder) {
	for _, t := range r.Tuples {
		b.WriteString(r.Pred)
		b.WriteByte('(')
		for i, c := range t {
			if i > 0 {
				b.WriteString(", ")
			}
			b.WriteString(c.String())
		}
		b.WriteString(")\n")
	}
	b.WriteString("-- ")
	b.WriteString(itoa(len(r.Tuples)))
	b.WriteByte('\n')
}

// Run parses and evaluates src and returns the text of the answers to all of
// its queries, in order. Unsafe or unstratifiable programs yield an error
// wrapping ErrUnsafe or ErrNotStratifiable, and no output.
func Run(src []byte) ([]byte, error) {
	p, err := Parse(src)
	if err != nil {
		return nil, err
	}
	m, err := p.Eval()
	if err != nil {
		return nil, err
	}
	// Format with precomputed constant texts: each constant is rendered once.
	text := make([]string, len(p.Consts))
	for i, c := range p.Consts {
		text[i] = c.String()
	}
	var out bytes.Buffer
	for _, q := range p.Queries {
		name := p.Preds[q.Pred].Name
		rows := m.db.Match(q)
		for _, row := range rows {
			out.WriteString(name)
			out.WriteByte('(')
			for j, id := range row {
				if j > 0 {
					out.WriteString(", ")
				}
				out.WriteString(text[id])
			}
			out.WriteString(")\n")
		}
		out.WriteString("-- ")
		out.WriteString(itoa(len(rows)))
		out.WriteByte('\n')
	}
	return out.Bytes(), nil
}

// IsRejected reports whether err means the program was rejected by the static
// checks (unsafe or not stratifiable) rather than being malformed.
func IsRejected(err error) bool {
	return errors.Is(err, ErrUnsafe) || errors.Is(err, ErrNotStratifiable)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
