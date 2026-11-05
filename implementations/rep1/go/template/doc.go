// Package template implements a small Jinja2-style template engine: variables
// and expressions, a fixed set of filters, if/for/set, macros, include, and
// template inheritance with extends, block and super().
//
// The package is organised by responsibility:
//
//	errors.go, value.go, scope.go   values, errors and scopes
//	lexer.go, parser.go, ast.go     template source to AST
//	eval.go, interp.go, ops.go      the tree-walking interpreter
//	filters.go, print.go            filters and value printing
//	json.go, bundle.go              ordered JSON and the stdin bundle format
//	engine.go, convert.go           the public entry points
//
// Typical use:
//
//	eng := template.NewEngine(map[string]string{"main": "Hello {{ name|upper }}!"})
//	out, err := eng.Render("main", template.ContextFromMap(map[string]any{"name": "ada"}))
//
// Failures are returned as *Error values whose Kind is one of ErrSyntax,
// ErrFilter, ErrUndefined, ErrTemplate and ErrType. Rendering is
// all-or-nothing: on error no partial output is returned.
package template
