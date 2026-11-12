// Package datalog is a small Datalog engine with stratified negation.
//
// A program is a sequence of facts, rules and queries:
//
//	edge(1, 2). edge(2, 3).
//	path(X, Y) :- edge(X, Y).
//	path(X, Z) :- edge(X, Y), path(Y, Z).
//	?- path(1, X).
//
// Load parses a program, rejects unsafe or unstratifiable ones, and
// computes the perfect model bottom-up (semi-naive evaluation). Run does the
// same and writes the answers to the program's queries in the textual format
// used by the command-line tool.
//
// The work is split across subpackages: ast (syntax tree and constant
// order), parser, analysis (safety and stratification) and engine
// (evaluation).
package datalog

import (
	"bufio"
	"fmt"
	"io"
	"strconv"

	"example.com/datalog/analysis"
	"example.com/datalog/ast"
	"example.com/datalog/engine"
	"example.com/datalog/parser"
)

// Errors reported by Load, re-exported for use with errors.Is.
var (
	ErrUnsafe          = analysis.ErrUnsafe
	ErrNotStratifiable = analysis.ErrNotStratifiable
)

// Tuple is one answer row.
type Tuple = engine.Tuple

// Constant is an integer or symbol.
type Constant = ast.Constant

// Answer is the result of one query.
type Answer struct {
	Query  ast.Atom
	Tuples []Tuple
}

// DB is an evaluated program: its model plus the queries it contained.
type DB struct {
	prog *ast.Program
	db   *engine.Database
}

// Load parses src, checks it (safety first, then stratifiability) and
// evaluates it. Syntax errors are *parser.SyntaxError; the other failures
// wrap ErrUnsafe or ErrNotStratifiable.
func Load(src string) (*DB, error) {
	prog, err := parser.Parse(src)
	if err != nil {
		return nil, err
	}
	return Evaluate(prog)
}

// Evaluate checks and evaluates an already parsed program.
func Evaluate(prog *ast.Program) (*DB, error) {
	if err := analysis.CheckSafety(prog); err != nil {
		return nil, err
	}
	strata, err := analysis.Stratify(prog)
	if err != nil {
		return nil, err
	}
	return &DB{prog: prog, db: engine.Evaluate(prog, strata)}, nil
}

// Answers returns the answers to the program's own queries, in program order.
func (d *DB) Answers() []Answer {
	out := make([]Answer, len(d.prog.Queries))
	for i, q := range d.prog.Queries {
		out[i] = Answer{q, d.db.Query(q)}
	}
	return out
}

// Query answers an ad hoc query such as "path(1, X)" (an optional leading
// "?-" and trailing "." are accepted) against the model.
func (d *DB) Query(src string) ([]Tuple, error) {
	a, err := parser.ParseAtom(src)
	if err != nil {
		return nil, err
	}
	return d.db.Query(a), nil
}

// Format renders a tuple of predicate pred as "pred(v1, v2)".
func Format(pred string, t Tuple) string {
	b := make([]byte, 0, 32)
	b = append(b, pred...)
	b = append(b, '(')
	for i, c := range t {
		if i > 0 {
			b = append(b, ", "...)
		}
		if c.IsInt() {
			b = strconv.AppendInt(b, c.IntValue(), 10)
		} else {
			b = append(b, c.SymValue()...)
		}
	}
	return string(append(b, ')'))
}

// WriteAnswers writes each answer: its tuples one per line, then "-- N".
func WriteAnswers(w io.Writer, answers []Answer) error {
	bw := bufio.NewWriter(w)
	for _, a := range answers {
		for _, t := range a.Tuples {
			bw.WriteString(Format(a.Query.Pred, t))
			bw.WriteByte('\n')
		}
		fmt.Fprintf(bw, "-- %d\n", len(a.Tuples))
	}
	return bw.Flush()
}

// Run reads a program from r, evaluates it and writes the answers to its
// queries to w. Program errors are returned without writing anything.
func Run(r io.Reader, w io.Writer) error {
	src, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	db, err := Load(string(src))
	if err != nil {
		return err
	}
	return WriteAnswers(w, db.Answers())
}
