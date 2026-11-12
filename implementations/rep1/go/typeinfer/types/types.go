// Package types implements the type language of typeinfer: a shared graph of
// type nodes with union-find unification, level-based generalisation and
// instantiation, and a printer.
//
// Types are mutable graphs. A [Type] is either a type variable, which may be
// bound to another type by unification, or a constructor (int, bool, unit,
// function, tuple, list) that refers to its component types. Sub-terms may be
// shared freely, so the number of distinct nodes of a type can be much smaller
// than the size of the type written out as a tree. Every algorithm in this
// package visits each distinct node at most once.
//
// All mutation (unification, generalisation, instantiation, fresh variables)
// goes through a [Context]. A Context is not safe for concurrent use, and
// types created by one Context must not be used with another.
package types

// Kind classifies a type node.
type Kind uint8

// The kinds of type nodes.
const (
	KindVar   Kind = iota // a type variable (possibly bound to another type)
	KindInt               // int
	KindBool              // bool
	KindUnit              // unit
	KindArrow             // function type: 2 components (parameter, result)
	KindTuple             // tuple type: 2 or more components
	KindList              // list type: 1 component (the element type)
)

// genericLevel marks a type variable that has been quantified by
// generalisation. It is larger than any real level.
const genericLevel = int32(1<<31 - 1)

// Type is a node in a type graph. The zero value is not usable; create types
// with the constructors in this package.
type Type struct {
	kind  Kind
	level int32   // variables: binding level (genericLevel if quantified)
	id    int32   // variables: creation number, for debugging only
	mark  uint32  // visit stamp of the most recent walk that reached this node
	link  *Type   // union-find forward pointer; nil for a representative
	copy  *Type   // instantiation: the copy made during the walk stamped mark
	args  []*Type // components of constructors
}

// The three nullary constructors are singletons. They are never mutated, so
// they may be shared by any number of Contexts.
var (
	// Int is the type int.
	Int = &Type{kind: KindInt}
	// Bool is the type bool.
	Bool = &Type{kind: KindBool}
	// Unit is the type unit.
	Unit = &Type{kind: KindUnit}
)

// Arrow returns the function type from -> to.
func Arrow(from, to *Type) *Type {
	return &Type{kind: KindArrow, args: []*Type{from, to}}
}

// List returns the type elem list.
func List(elem *Type) *Type {
	return &Type{kind: KindList, args: []*Type{elem}}
}

// Tuple returns the tuple type of the given components. It panics if fewer
// than two components are given. The slice is retained.
func Tuple(elems []*Type) *Type {
	if len(elems) < 2 {
		panic("types: tuple needs at least two components")
	}
	return &Type{kind: KindTuple, args: elems}
}

// find returns the representative of t, compressing the path.
func find(t *Type) *Type {
	r := t
	for r.link != nil {
		r = r.link
	}
	for t.link != nil {
		next := t.link
		t.link = r
		t = next
	}
	return r
}

// Resolve returns the representative of t: t itself unless t is a variable
// that has been bound (or a constructor that has been merged with an equal
// one), in which case the type it stands for.
func (t *Type) Resolve() *Type { return find(t) }

// Kind reports the kind of t after resolution.
func (t *Type) Kind() Kind { return find(t).kind }

// Args returns the components of t after resolution: the parameter and result
// of a function, the elements of a tuple, the element of a list; nil for
// variables and base types. The result must not be modified.
func (t *Type) Args() []*Type { return find(t).args }

// IsGeneric reports whether t resolves to a quantified type variable.
func (t *Type) IsGeneric() bool {
	r := find(t)
	return r.kind == KindVar && r.level == genericLevel
}

// Scheme is a type scheme: a type together with the variables of it that are
// universally quantified. Quantified variables are marked in the type graph
// itself, so a Scheme is just the type plus a flag saying whether anything is
// quantified.
type Scheme struct {
	// Type is the body of the scheme.
	Type *Type
	// Poly is true if Type contains quantified variables. A scheme that is
	// not Poly is a monomorphic type and instantiates to itself in O(1).
	Poly bool
}

// Mono returns the monomorphic scheme of t.
func Mono(t *Type) *Scheme { return &Scheme{Type: t} }
