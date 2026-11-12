// Package template is a Jinja-style template engine.
//
// It implements a subset of Jinja2 3.1 (with strict undefined handling and
// no automatic whitespace trimming or escaping): variables and expressions,
// thirteen filters, if/for/set, macros, include, template inheritance with
// extends/block/super(), comments and whitespace control.
//
// Usage:
//
//	env := template.NewEnvironment()
//	env.Add("main", "Hello {{ name|upper }}!")
//	out, err := env.Render("main", map[string]any{"name": "Ada"})
//
// Templates are parsed lazily the first time they are rendered, included or
// extended, and at most once per Environment. Every failure is a *Error whose
// Kind is one of Syntax, Filter, Undefined, Template or Type.
//
// The engine is organised in layers: package syntax turns source into a
// tree, package value defines the dynamic values and operators, package
// filters the built-in filters, package jsonctx reads JSON contexts, and
// this package interprets the tree.
package template
