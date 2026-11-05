// Package vellum is the public entry point of the toolchain: it compiles a
// multi-module Vellum program from source text and runs it.
//
// The pipeline is source text -> modules -> tokens -> AST -> name resolution
// and type checking -> bytecode -> execution on a stack VM.
package vellum

import (
	"langvm/ast"
	"langvm/bytecode"
	"langvm/check"
	"langvm/compile"
	"langvm/diag"
	"langvm/lexer"
	"langvm/parser"
	"langvm/vm"
)

// Check runs every front-end pass (SPEC 13.2 passes 0 to 4) and returns the
// annotated program or the first diagnostic.
func Check(src []byte) (*check.Program, *diag.Error) {
	mods, err := SplitModules(src)
	if err != nil {
		return nil, err
	}
	toks := make([][]lexer.Token, len(mods))
	for i, m := range mods {
		t, lerr := lexer.Lex(m.Body)
		if lerr != nil {
			return nil, lerr
		}
		toks[i] = t
	}
	asts := make([]*ast.Module, len(mods))
	for i, m := range mods {
		a, perr := parser.Parse(m.Name, toks[i])
		if perr != nil {
			return nil, perr
		}
		asts[i] = a
	}
	return check.Check(asts)
}

// Compile runs the whole compiler and returns the bytecode program.
func Compile(src []byte) (*bytecode.Program, *diag.Error) {
	p, err := Check(src)
	if err != nil {
		return nil, err
	}
	return compile.Compile(p), nil
}

// Run compiles and executes a program and returns exactly what the tool
// prints on stdout: the program's output (followed by a panic line if it
// panicked), or a single diagnostic line if it does not compile.
func Run(src []byte) []byte {
	prog, err := Compile(src)
	if err != nil {
		return []byte(err.Error() + "\n")
	}
	return vm.Load(prog).Run()
}
