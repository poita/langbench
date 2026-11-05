// Package syntax implements the front end of typeinfer: a lexer and a
// recursive-descent parser for a small ML-like language.
//
// A program is a sequence of declarations, each terminated by ";;". The
// parser produces a compact, index-based AST (see Program and Node) in which
// all identifiers are interned to dense integer ids through an Interner, and
// in which "let f x y = e" and "fun x y -> e" are already desugared to nested
// single-parameter functions.
//
// The package knows nothing about types; package typeinfer consumes the AST.
package syntax
