// Package datalog is a Datalog engine with stratified negation and integer /
// symbol constants.
//
// A program is parsed with [Parse], checked and evaluated with [Evaluate]
// (bottom-up, semi-naive, one fixpoint per strongly connected component of the
// predicate dependency graph), and then queried with [Model.Query]. [Run]
// does all of this for a source text and answers its queries.
//
// Constants are totally ordered: integers (numerically) before identifiers
// (bytewise). The comparison operators and the order of query answers use this
// order.
package datalog

import (
	"fmt"
	"io"
	"strings"

	"example.com/datalog/analysis"
	"example.com/datalog/ast"
	"example.com/datalog/engine"
	"example.com/datalog/parser"
)

// Re-exported types, so that simple clients need only this package.
type (
	// Program is a parsed program.
	Program = ast.Program
	// Atom is a predicate applied to terms.
	Atom = ast.Atom
	// Value is an integer or symbol constant.
	Value = ast.Value
	// UnsafeError is returned for a rule that violates the safety condition.
	UnsafeError = analysis.UnsafeError
	// NotStratifiableError is returned when negation lies on a recursive cycle.
	NotStratifiableError = analysis.NotStratifiableError
	// SyntaxError is returned for malformed source text.
	SyntaxError = parser.SyntaxError
)

// Tuple is one row of a relation.
type Tuple []Value

// Parse parses program text.
func Parse(src string) (*Program, error) { return parser.Parse(src) }

// Model is the computed perfect model of a program.
type Model struct {
	db *engine.DB
}

// Evaluate checks that prog is safe (reporting an *UnsafeError otherwise) and
// stratifiable (a *NotStratifiableError otherwise) and computes its model.
func Evaluate(prog *Program) (*Model, error) {
	if err := analysis.CheckSafety(prog.Rules); err != nil {
		return nil, err
	}
	comps, err := analysis.Stratify(prog.Rules)
	if err != nil {
		return nil, err
	}
	return &Model{db: engine.Evaluate(prog.Rules, comps)}, nil
}

// Query returns the tuples matching the pattern atom, in ascending order.
// Constants in the pattern must match; a variable repeated in the pattern must
// match equal values; `_` (an anonymous variable) matches anything.
func (m *Model) Query(pattern Atom) []Tuple {
	rows := m.db.Query(pattern)
	out := make([]Tuple, len(rows))
	for i, r := range rows {
		out[i] = Tuple(r)
	}
	return out
}

// Result is the answer to one query.
type Result struct {
	Query  Atom
	Tuples []Tuple
}

// Run parses and evaluates src and answers each of its queries in order.
func Run(src string) ([]Result, error) {
	prog, err := Parse(src)
	if err != nil {
		return nil, err
	}
	m, err := Evaluate(prog)
	if err != nil {
		return nil, err
	}
	res := make([]Result, len(prog.Queries))
	for i, q := range prog.Queries {
		res[i] = Result{Query: q, Tuples: m.Query(q)}
	}
	return res, nil
}

// Format renders the tuple as name(v1, v2, ...).
func (t Tuple) Format(name string) string {
	var sb strings.Builder
	sb.WriteString(name)
	sb.WriteByte('(')
	for i, v := range t {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString(v.String())
	}
	sb.WriteByte(')')
	return sb.String()
}

// WriteResults writes results in the CLI's output format: for each query, one
// line per matching tuple followed by a line "-- N".
func WriteResults(w io.Writer, results []Result) error {
	for _, r := range results {
		for _, t := range r.Tuples {
			if _, err := io.WriteString(w, t.Format(r.Query.Name)+"\n"); err != nil {
				return err
			}
		}
		if _, err := fmt.Fprintf(w, "-- %d\n", len(r.Tuples)); err != nil {
			return err
		}
	}
	return nil
}
