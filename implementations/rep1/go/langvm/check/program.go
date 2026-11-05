// Package check performs name resolution, type checking and pattern analysis
// of a parsed Vellum program (SPEC sections 5 to 13). It reports the first
// diagnostic in the order the specification defines, and otherwise returns an
// annotated Program for the bytecode compiler.
package check

import "langvm/ast"

// TypeParam is a generic parameter. T is its rigid type.
type TypeParam struct {
	Name   string
	Bounds []*Trait
	T      *Type
}

func newParam(name string) *TypeParam {
	p := &TypeParam{Name: name}
	p.T = &Type{Kind: KParam, Param: p}
	return p
}

// hasBound reports whether the parameter declares trait tr.
func (p *TypeParam) hasBound(tr *Trait) bool {
	for _, b := range p.Bounds {
		if b == tr {
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

// Variant is an enum variant.
type Variant struct {
	Name    string
	Enum    *TypeDecl
	Index   int
	Payload []*Type
	Pos     ast.Pos
}

// TypeDecl is a struct or an enum declaration (including the prelude's
// Option and Result).
type TypeDecl struct {
	Name     string
	Mod      *Module
	Pub      bool
	IsEnum   bool
	ID       int
	Params   []*TypeParam
	Fields   []Field
	Variants []*Variant
	Struct   *ast.StructDecl
	Enum     *ast.EnumDecl
}

// Trait is a user trait or one of the built-in Eq, Ord, Key.
type Trait struct {
	Name    string
	Mod     *Module
	Pub     bool
	Builtin int // 0 user trait; 1 Eq; 2 Ord; 3 Key
	ID      int
	Methods []*Method
	ByName  map[string]*Method
	Self    *TypeParam // the rigid Self of default bodies
	Decl    *ast.TraitDecl
}

// Built-in trait ids.
const (
	BEq  = 1
	BOrd = 2
	BKey = 3
)

// Method is a trait method declaration.
type Method struct {
	Name    string
	Trait   *Trait
	Index   int
	Params  []*Type // excluding self; Self is Trait.Self.T
	Ret     *Type
	Default *Func // default body, or nil
	Decl    *ast.FnDecl
}

// Func is a function with a body (user function, impl method or trait
// default body) or a built-in.
type Func struct {
	Name    string
	Mod     *Module
	Pub     bool
	Decl    *ast.FnDecl
	TParams []*TypeParam
	Params  []*Type // excluding self
	Ret     *Type
	Builtin int // built-in id, or -1

	Trait  *Trait // for impl methods and default bodies
	Impl   *Impl
	Method *Method
	Info   *FnInfo // set when the body is checked
	ID     int     // assigned by the compiler
}

// Impl is a registered trait implementation.
type Impl struct {
	Trait   *Trait
	Mod     *Module
	TParams []*TypeParam
	Head    *Type
	Ctor    int
	Methods []*Func // indexed by trait method index; nil = use the default
	Decl    *ast.ImplDecl
}

// Module is a module with its four namespaces.
type Module struct {
	Name    string
	Index   int
	AST     *ast.Module
	Types   map[string]*TypeDecl
	Traits  map[string]*Trait
	Values  map[string]any // *Func or *Variant
	Imports map[string]*Module
	// declaration order of own traits, for deterministic iteration
	TraitList []*Trait
	Funcs     []*Func // bodies in source order (functions, impl methods, defaults)
}

// Local is a local binding.
type Local struct {
	Name    string
	Mutable bool
	Type    *Type
	Owner   *FnInfo
	Slot    int // assigned by the compiler
}

// FnInfo describes one function body or lambda.
type FnInfo struct {
	Parent   *FnInfo
	Func     *Func
	Lambda   *ast.Lambda
	Params   []*Local // includes self first for methods
	Ret      *Type    // nil while unknown (lambda in synthesis mode)
	Captures []*Local
	CapIndex map[*Local]int
	Loops    int
}

func (f *FnInfo) capture(l *Local) int {
	if i, ok := f.CapIndex[l]; ok {
		return i
	}
	if f.CapIndex == nil {
		f.CapIndex = map[*Local]int{}
	}
	f.CapIndex[l] = len(f.Captures)
	f.Captures = append(f.Captures, l)
	return len(f.Captures) - 1
}

// Program is the result of checking: everything the compiler needs.
type Program struct {
	Modules   []*Module
	Types     []*TypeDecl // by ID
	Traits    []*Trait    // user traits, by ID
	Impls     []*Impl
	Funcs     []*Func // all functions with bodies, in checking order
	Main      *Func
	Prelude   *Module
	NumCtors  int
	Option    *TypeDecl
	Result    *TypeDecl
	nextTrait int
}

// TraitMethodRef is the annotation of a `Tr::m` path used as a callee.
type TraitMethodRef struct {
	Trait  *Trait
	Method *Method
}

// MethodRes annotates a method call.
type MethodRes struct {
	Trait  *Trait
	Method *Method
}

// CallRes annotates a call expression.
type CallRes struct {
	Kind    int // CallFunc, CallBuiltin, CallVariant, CallValue, CallTraitMethod
	Func    *Func
	Variant *Variant
	Trait   *TraitMethodRef
}

// Call kinds.
const (
	CallFunc = iota
	CallBuiltin
	CallVariant
	CallValue
	CallTraitMethod
)

// Sem values recorded on operators.
const (
	SemInt = iota
	SemFloat
	SemStr
	SemList
	SemMap
	SemBool
)
