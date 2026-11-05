package typeinfer

// ErrorKind classifies why a declaration failed to type-check.
type ErrorKind uint8

// Error kinds. When a declaration has several problems, the one reported is
// the first met by a left-to-right inference pass that unifies as it goes.
const (
	// NoError means the declaration type-checked.
	NoError ErrorKind = iota
	// ErrUnbound: a variable is not in scope.
	ErrUnbound
	// ErrOccurs: unification would build an infinite type.
	ErrOccurs
	// ErrUnify: any other unification failure (constructor or arity mismatch).
	ErrUnify
)

// String returns "unbound", "occurs", "unify", or "" for NoError.
func (k ErrorKind) String() string {
	switch k {
	case ErrUnbound:
		return "unbound"
	case ErrOccurs:
		return "occurs"
	case ErrUnify:
		return "unify"
	}
	return ""
}

// typeError is the panic payload used to abort inference of a declaration.
type typeError struct{ kind ErrorKind }

func fail(k ErrorKind) { panic(typeError{k}) }
