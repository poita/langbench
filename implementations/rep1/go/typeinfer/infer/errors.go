package infer

import "fmt"

// ErrorKind says why a declaration does not type-check.
type ErrorKind string

// The kinds of type error.
const (
	// Unbound: a variable is not in scope.
	Unbound ErrorKind = "unbound"
	// Occurs: unification would build an infinite type.
	Occurs ErrorKind = "occurs"
	// Unify: any other unification failure.
	Unify ErrorKind = "unify"
)

// Error is a type error in one declaration.
type Error struct {
	Kind ErrorKind
	// Name is the unbound variable, for Unbound errors.
	Name string
}

func (e *Error) Error() string {
	if e.Kind == Unbound {
		return fmt.Sprintf("unbound variable %q", e.Name)
	}
	return string(e.Kind)
}
