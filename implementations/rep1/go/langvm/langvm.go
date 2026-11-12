// Package langvm is a compiler and stack virtual machine for Vellum, the
// small statically typed language defined in SPEC.md.
//
// A program is a stream of modules ("@module name" headers followed by
// bodies). Compile checks a whole stream and produces a Program; Program.Run
// executes it:
//
//	prog, diagnostic := langvm.Compile(src)
//	if diagnostic != nil {
//		fmt.Println(diagnostic) // "error: type-mismatch at 3:15"
//		return
//	}
//	if err := prog.Run(os.Stdout); err != nil {
//		fmt.Println(err) // "panic: index out of bounds"
//	}
//
// The pipeline is source -> tokens -> syntax tree -> name resolution and type
// checking -> bytecode -> execution, one sub-package per stage: source,
// lexer, parser, check, compiler and vm.
package langvm

import (
	"io"

	"langvm/ast"
	"langvm/bytecode"
	"langvm/check"
	"langvm/compiler"
	"langvm/diag"
	"langvm/lexer"
	"langvm/parser"
	"langvm/source"
	"langvm/vm"
)

// Diagnostic is the single compile-time error reported for a rejected
// program. Its Error method renders the exact line "error: <kind> at L:C".
type Diagnostic = diag.Error

// Panic is the error returned by Program.Run when the program panics. Its
// Error method renders the exact line "panic: <message>".
type Panic = vm.Panic

// Program is a compiled Vellum program.
type Program struct {
	code *bytecode.Program
}

// Compile compiles a module stream. It returns the first diagnostic in the
// pass order of the specification, or a runnable Program.
func Compile(input []byte) (*Program, *Diagnostic) {
	mods, err := source.Split(string(input))
	if err != nil {
		return nil, err
	}
	toks := make([][]lexer.Token, len(mods))
	for i, m := range mods {
		t, err := lexer.Lex(m.Lines)
		if err != nil {
			return nil, err
		}
		toks[i] = t
	}
	parsed := make([]*ast.Module, len(mods))
	for i, m := range mods {
		pm, err := parser.Parse(m.Name, toks[i])
		if err != nil {
			return nil, err
		}
		parsed[i] = pm
	}
	checked, err := check.Check(parsed)
	if err != nil {
		return nil, err
	}
	return &Program{code: compiler.Compile(checked)}, nil
}

// Run executes the program, writing everything it prints to w. It returns
// nil if main returns normally and a *Panic if the program panics at run
// time; output printed before the panic has been written to w, and the panic
// line itself has not.
func (p *Program) Run(w io.Writer) error {
	return vm.Run(p.code, w)
}

// Run compiles and runs a module stream in one call. A compile error is
// returned as a *Diagnostic and a run-time panic as a *Panic.
func Run(input []byte, w io.Writer) error {
	p, d := Compile(input)
	if d != nil {
		return d
	}
	return p.Run(w)
}
