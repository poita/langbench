// Package types defines the semantic objects shared by the checker and the
// bytecode compiler: types, declarations, traits, impls and local variables.
package types

import "strings"

// Kind discriminates the forms of a semantic type (SPEC.md section 6.1).
type Kind uint8

// Type kinds. The first six are the primitives, in head-constructor order.
const (
	KInt Kind = iota
	KFloat
	KBool
	KChar
	KStr
	KUnit
	KList
	KMap
	KTuple
	KFunc
	KNamed
	KParam
	KVar
)

// Type is a semantic type. Types are immutable except for inference
// variables, which are bound in place.
type Type struct {
	Kind  Kind
	Args  []*Type    // list: [elem]; map: [K, V]; tuple: parts; func: params; named: type arguments
	Ret   *Type      // func: return type
	Decl  *Decl      // named: the declaration
	Param *TypeParam // param: the generic parameter
	Ref   *Type      // var: its solution, nil while unsolved
	ID    int        // var: creation number
}

// Primitive type singletons.
var (
	Int   = &Type{Kind: KInt}
	Float = &Type{Kind: KFloat}
	Bool  = &Type{Kind: KBool}
	Char  = &Type{Kind: KChar}
	Str   = &Type{Kind: KStr}
	Unit  = &Type{Kind: KUnit}
)

// Head constructor codes: primitives are 0..5, List 6, Map 7, and a named
// type is 8 plus its declaration id.
const (
	CtorList     = 6
	CtorMap      = 7
	CtorDeclBase = 8
)

// NewList returns the type [elem].
func NewList(elem *Type) *Type { return &Type{Kind: KList, Args: []*Type{elem}} }

// NewMap returns the type #[k: v].
func NewMap(k, v *Type) *Type { return &Type{Kind: KMap, Args: []*Type{k, v}} }

// NewTuple returns a tuple type.
func NewTuple(parts []*Type) *Type { return &Type{Kind: KTuple, Args: parts} }

// NewFunc returns a function type.
func NewFunc(params []*Type, ret *Type) *Type {
	return &Type{Kind: KFunc, Args: params, Ret: ret}
}

// NewNamed returns the named type decl<args>.
func NewNamed(d *Decl, args []*Type) *Type { return &Type{Kind: KNamed, Decl: d, Args: args} }

// NewParam returns the type that stands for the generic parameter p.
func NewParam(p *TypeParam) *Type { return &Type{Kind: KParam, Param: p} }

// Module identifies a module of the program.
type Module struct {
	Name  string
	Index int
}

// BuiltinTrait identifies the three built-in traits.
type BuiltinTrait uint8

// The built-in traits (section 7).
const (
	UserTrait BuiltinTrait = iota
	TraitEq
	TraitOrd
	TraitKey
)

// TypeParam is a generic parameter with its bounds.
type TypeParam struct {
	Name   string
	Bounds []*Trait
}

// HasBound reports whether the parameter's bounds include trait t.
func (p *TypeParam) HasBound(t *Trait) bool {
	for _, b := range p.Bounds {
		if b == t {
			return true
		}
	}
	return false
}

// HasBuiltin reports whether any bound is the given built-in trait.
func (p *TypeParam) HasBuiltin(k BuiltinTrait) bool {
	for _, b := range p.Bounds {
		if b.Builtin == k {
			return true
		}
	}
	return false
}

// Field is a struct field.
type Field struct {
	Name string
	Type *Type
}

// Variant is one variant of an enum.
type Variant struct {
	Name    string
	Index   int
	Decl    *Decl
	Payload []*Type
}

// Decl is a struct or enum declaration.
type Decl struct {
	ID       int
	Name     string
	Module   *Module // nil for the prelude
	Pub      bool
	IsEnum   bool
	TParams  []*TypeParam
	Fields   []Field    // struct
	Variants []*Variant // enum
}

// FieldIndex returns the index of the named field or -1.
func (d *Decl) FieldIndex(name string) int {
	for i, f := range d.Fields {
		if f.Name == name {
			return i
		}
	}
	return -1
}

// Func is a function: user function, impl method, trait default body or
// built-in. Lambdas are described by Body only.
type Func struct {
	Name    string
	Module  *Module // nil for built-ins
	Pub     bool
	TParams []*TypeParam
	Params  []*Type // including self for methods
	Ret     *Type
	Builtin int   // built-in id, or -1
	Index   int   // function table index, assigned by the compiler
	Body    *Body // checked body; nil for built-ins
}

// TraitMethod is a method signature of a trait. Params excludes self; the
// trait's Self type is the Param type of Trait.SelfParam.
type TraitMethod struct {
	Name       string
	Index      int
	Params     []*Type
	Ret        *Type
	HasDefault bool
	Default    *Func // default body, if any
}

// Trait is a user-defined or built-in trait.
type Trait struct {
	ID        int
	Name      string
	Module    *Module
	Pub       bool
	Builtin   BuiltinTrait
	Methods   []*TraitMethod
	SelfParam *TypeParam
}

// MethodIndex returns the index of the named method, or -1.
func (t *Trait) MethodIndex(name string) int {
	for i, m := range t.Methods {
		if m.Name == name {
			return i
		}
	}
	return -1
}

// Impl is a trait implementation. Methods holds, for each trait method, the
// impl's own function or nil when the trait's default body applies.
type Impl struct {
	Trait   *Trait
	Ctor    int
	TParams []*TypeParam
	Head    *Type
	Methods []*Func
}

// Local is a local variable, parameter or pattern binding.
type Local struct {
	Name    string
	Type    *Type
	Mutable bool
	Owner   *Body
	Slot    int // assigned by the compiler
}

// Body describes one function body (function, method, default body or
// lambda): its parameters and the variables it captures from enclosing
// functions.
type Body struct {
	Params   []*Local
	Captures []*Local // in capture order; index = upvalue number
	Parent   *Body
}

// Resolve follows solved inference variables.
func Resolve(t *Type) *Type {
	for t.Kind == KVar && t.Ref != nil {
		t = t.Ref
	}
	return t
}

// Ctor returns the head constructor code of t, or -1 for tuples, functions,
// parameters and variables.
func (t *Type) Ctor() int {
	switch t.Kind {
	case KInt, KFloat, KBool, KChar, KStr, KUnit:
		return int(t.Kind)
	case KList:
		return CtorList
	case KMap:
		return CtorMap
	case KNamed:
		return CtorDeclBase + t.Decl.ID
	}
	return -1
}

// Subst replaces generic parameters according to m, resolving solved
// variables on the way.
func Subst(t *Type, m map[*TypeParam]*Type) *Type {
	t = Resolve(t)
	switch t.Kind {
	case KParam:
		if r, ok := m[t.Param]; ok {
			return r
		}
		return t
	case KList, KMap, KTuple, KNamed, KFunc:
		changed := false
		args := make([]*Type, len(t.Args))
		for i, a := range t.Args {
			args[i] = Subst(a, m)
			if args[i] != a {
				changed = true
			}
		}
		var ret *Type
		if t.Kind == KFunc {
			ret = Subst(t.Ret, m)
			if ret != t.Ret {
				changed = true
			}
		}
		if !changed {
			return t
		}
		return &Type{Kind: t.Kind, Args: args, Ret: ret, Decl: t.Decl}
	}
	return t
}

// Equal reports structural equality of two types without unification.
func Equal(a, b *Type) bool {
	a, b = Resolve(a), Resolve(b)
	if a == b {
		return true
	}
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case KParam:
		return a.Param == b.Param
	case KVar:
		return false
	case KNamed:
		if a.Decl != b.Decl {
			return false
		}
	case KFunc:
		if !Equal(a.Ret, b.Ret) {
			return false
		}
	}
	if len(a.Args) != len(b.Args) {
		return false
	}
	for i := range a.Args {
		if !Equal(a.Args[i], b.Args[i]) {
			return false
		}
	}
	return true
}

// Occurs reports whether the unsolved variable v occurs in t.
func Occurs(v, t *Type) bool {
	t = Resolve(t)
	if t == v {
		return true
	}
	for _, a := range t.Args {
		if Occurs(v, a) {
			return true
		}
	}
	if t.Kind == KFunc {
		return Occurs(v, t.Ret)
	}
	return false
}

// Ground reports whether t contains no unsolved variable.
func Ground(t *Type) bool {
	t = Resolve(t)
	if t.Kind == KVar {
		return false
	}
	for _, a := range t.Args {
		if !Ground(a) {
			return false
		}
	}
	if t.Kind == KFunc {
		return Ground(t.Ret)
	}
	return true
}

// Unify makes a and b equal by solving variables, following SPEC.md 9.2.
// It reports whether unification succeeded; variables solved before a failure
// stay solved.
func Unify(a, b *Type) bool {
	a, b = Resolve(a), Resolve(b)
	if a.Kind == KVar {
		if a == b {
			return true
		}
		if Occurs(a, b) {
			return false
		}
		a.Ref = b
		return true
	}
	if b.Kind == KVar {
		if Occurs(b, a) {
			return false
		}
		b.Ref = a
		return true
	}
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case KParam:
		return a.Param == b.Param
	case KNamed:
		if a.Decl != b.Decl {
			return false
		}
	}
	if len(a.Args) != len(b.Args) {
		return false
	}
	for i := range a.Args {
		if !Unify(a.Args[i], b.Args[i]) {
			return false
		}
	}
	if a.Kind == KFunc {
		return Unify(a.Ret, b.Ret)
	}
	return true
}

// String renders a type for debugging.
func (t *Type) String() string {
	t = Resolve(t)
	switch t.Kind {
	case KInt:
		return "Int"
	case KFloat:
		return "Float"
	case KBool:
		return "Bool"
	case KChar:
		return "Char"
	case KStr:
		return "Str"
	case KUnit:
		return "Unit"
	case KList:
		return "[" + t.Args[0].String() + "]"
	case KMap:
		return "#[" + t.Args[0].String() + ": " + t.Args[1].String() + "]"
	case KTuple, KFunc, KNamed:
		parts := make([]string, len(t.Args))
		for i, a := range t.Args {
			parts[i] = a.String()
		}
		switch t.Kind {
		case KTuple:
			return "(" + strings.Join(parts, ", ") + ")"
		case KFunc:
			return "fn(" + strings.Join(parts, ", ") + ") -> " + t.Ret.String()
		}
		if len(parts) == 0 {
			return t.Decl.Name
		}
		return t.Decl.Name + "<" + strings.Join(parts, ", ") + ">"
	case KParam:
		return t.Param.Name
	}
	return "?"
}
