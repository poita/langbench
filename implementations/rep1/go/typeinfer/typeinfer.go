// Package typeinfer infers the principal types of the declarations of a small
// ML-like language with Hindley-Milner type inference and let-polymorphism.
//
// The language has integers, booleans, unit, functions, tuples and lists;
// let, let rec, fun and if expressions; and a handful of built-in functions.
// See the README for the full grammar. A program is a sequence of declarations
// each ending in ";;"; [Infer] returns, for every declaration, either its
// type or the kind of type error it contains.
//
// The implementation is split into three packages that can be used on their
// own: [github.com/example/typeinfer/syntax] (lexer, AST, parser),
// [github.com/example/typeinfer/types] (types, unification, generalisation,
// printing) and [github.com/example/typeinfer/infer] (the inference engine).
package typeinfer

import (
	"errors"
	"io"
	"strings"

	"github.com/example/typeinfer/infer"
	"github.com/example/typeinfer/syntax"
)

// Result describes one declaration of a program.
type Result struct {
	// Name is the declared name, or "" for a bare expression.
	Name string
	// Type is the principal type, in the printed syntax (for example
	// "('a -> 'b) -> 'a list -> 'b list"). It is empty if Err is set.
	Type string
	// Err is the type error, or nil if the declaration type-checks.
	Err *infer.Error
}

// String formats the result as one line of output, without the newline:
// "name : type", "- : type" or "error: kind".
func (r Result) String() string {
	if r.Err != nil {
		return "error: " + string(r.Err.Kind)
	}
	name := r.Name
	if name == "" {
		name = "-"
	}
	return name + " : " + r.Type
}

// Infer parses src and infers every declaration in order. Type errors are
// reported in the individual Results. If the program is syntactically
// malformed the results for the declarations before the error are returned
// together with a *syntax.Error.
func Infer(src string) ([]Result, error) {
	p := syntax.NewParser(src)
	in := infer.New()
	var results []Result
	for {
		d, err := p.Next()
		if err == io.EOF {
			return results, nil
		}
		if err != nil {
			return results, err
		}
		results = append(results, inferDecl(in, d))
	}
}

func inferDecl(in *infer.Inferer, d syntax.Decl) Result {
	res, err := in.Infer(d)
	if err != nil {
		var te *infer.Error
		errors.As(err, &te)
		return Result{Name: d.Name, Err: te}
	}
	return Result{Name: res.Name, Type: res.Scheme.String()}
}

// Run reads a whole program from r and writes one line per declaration to w,
// as documented on [Result.String]. Output produced before a syntax error is
// still written.
func Run(r io.Reader, w io.Writer) error {
	src, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	results, perr := Infer(string(src))
	var sb strings.Builder
	for _, res := range results {
		sb.WriteString(res.String())
		sb.WriteByte('\n')
	}
	if _, err := io.WriteString(w, sb.String()); err != nil {
		return err
	}
	return perr
}
