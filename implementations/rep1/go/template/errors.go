package template

import "example.com/template/tplerr"

// Error is the error type returned by the engine; see tplerr.
type Error = tplerr.Error

// Kind classifies an Error.
type Kind = tplerr.Kind

// The error kinds.
const (
	Syntax    = tplerr.Syntax
	Filter    = tplerr.Filter
	Undefined = tplerr.Undefined
	Template  = tplerr.Template
	Type      = tplerr.Type
)

// KindOf reports the Kind of an error returned by the engine.
func KindOf(err error) (Kind, bool) { return tplerr.KindOf(err) }
