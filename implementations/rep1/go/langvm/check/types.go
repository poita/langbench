package check

// Kind classifies a semantic type.
type Kind uint8

// Type kinds. The first eight values double as head-constructor ids.
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
	KFn
	KNamed
	KParam
	KVar
)

// Type is a semantic type (SPEC 6.1) or an inference variable.
//
//   - KList:  Elems = [elem]
//   - KMap:   Elems = [key, value]
//   - KTuple: Elems = components
//   - KFn:    Elems = parameters, Ret = result
//   - KNamed: Decl, Elems = type arguments
//   - KParam: Param (rigid generic parameter)
//   - KVar:   Ref is the binding once solved
type Type struct {
	Kind  Kind
	Elems []*Type
	Ret   *Type
	Decl  *TypeDecl
	Param *TypeParam
	Ref   *Type
}

// Primitive singletons.
var (
	TInt   = &Type{Kind: KInt}
	TFloat = &Type{Kind: KFloat}
	TBool  = &Type{Kind: KBool}
	TChar  = &Type{Kind: KChar}
	TStr   = &Type{Kind: KStr}
	TUnit  = &Type{Kind: KUnit}
)

func listOf(t *Type) *Type { return &Type{Kind: KList, Elems: []*Type{t}} }
func mapOf(k, v *Type) *Type {
	return &Type{Kind: KMap, Elems: []*Type{k, v}}
}

// prune follows variable bindings to the representative type.
func prune(t *Type) *Type {
	for t.Kind == KVar && t.Ref != nil {
		if t.Ref.Kind == KVar && t.Ref.Ref != nil {
			t.Ref = t.Ref.Ref // path compression
		}
		t = t.Ref
	}
	return t
}

// zonk returns t with every solved variable replaced by its solution.
func zonk(t *Type) *Type {
	t = prune(t)
	switch t.Kind {
	case KList, KMap, KTuple, KNamed, KFn:
		changed := false
		var elems []*Type
		for i, e := range t.Elems {
			z := zonk(e)
			if z != e && !changed {
				changed = true
				elems = make([]*Type, len(t.Elems))
				copy(elems, t.Elems[:i])
			}
			if changed {
				elems[i] = z
			}
		}
		var ret *Type
		if t.Ret != nil {
			ret = zonk(t.Ret)
			if ret != t.Ret {
				if !changed {
					elems = t.Elems
				}
				changed = true
			}
		}
		if !changed {
			return t
		}
		c := *t
		c.Elems = elems
		c.Ret = ret
		return &c
	}
	return t
}

func occurs(v, t *Type) bool {
	t = prune(t)
	if t == v {
		return true
	}
	for _, e := range t.Elems {
		if occurs(v, e) {
			return true
		}
	}
	if t.Ret != nil {
		return occurs(v, t.Ret)
	}
	return false
}

// unify makes a and b equal, solving variables. A variable on the left is
// solved first (SPEC 9.2).
func unify(a, b *Type) bool {
	a, b = prune(a), prune(b)
	if a == b {
		return true
	}
	if a.Kind == KVar {
		if occurs(a, b) {
			return false
		}
		a.Ref = b
		return true
	}
	if b.Kind == KVar {
		if occurs(b, a) {
			return false
		}
		b.Ref = a
		return true
	}
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case KList, KMap, KTuple, KFn, KNamed:
		if a.Kind == KNamed && a.Decl != b.Decl {
			return false
		}
		if len(a.Elems) != len(b.Elems) {
			return false
		}
		for i := range a.Elems {
			if !unify(a.Elems[i], b.Elems[i]) {
				return false
			}
		}
		if a.Kind == KFn {
			return unify(a.Ret, b.Ret)
		}
		return true
	case KParam:
		return a.Param == b.Param
	}
	return true // equal primitives
}

// equalTypes is structural equality without solving variables.
func equalTypes(a, b *Type) bool {
	a, b = prune(a), prune(b)
	if a == b {
		return true
	}
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case KList, KMap, KTuple, KFn, KNamed:
		if a.Kind == KNamed && a.Decl != b.Decl {
			return false
		}
		if len(a.Elems) != len(b.Elems) {
			return false
		}
		for i := range a.Elems {
			if !equalTypes(a.Elems[i], b.Elems[i]) {
				return false
			}
		}
		if a.Kind == KFn {
			return equalTypes(a.Ret, b.Ret)
		}
		return true
	case KParam:
		return a.Param == b.Param
	case KVar:
		return false
	}
	return true
}

// subst replaces type parameters according to m.
func subst(t *Type, m map[*TypeParam]*Type) *Type {
	t = prune(t)
	switch t.Kind {
	case KParam:
		if r, ok := m[t.Param]; ok {
			return r
		}
		return t
	case KList, KMap, KTuple, KNamed, KFn:
		changed := false
		elems := make([]*Type, len(t.Elems))
		for i, e := range t.Elems {
			elems[i] = subst(e, m)
			if elems[i] != e {
				changed = true
			}
		}
		var ret *Type
		if t.Ret != nil {
			ret = subst(t.Ret, m)
			if ret != t.Ret {
				changed = true
			}
		}
		if !changed {
			return t
		}
		c := *t
		c.Elems = elems
		c.Ret = ret
		return &c
	}
	return t
}

// ctor ids: head constructors for impl lookup and dispatch.
const (
	CtorList = 6
	CtorMap  = 7
	// CtorDeclBase + decl id is the head constructor of a struct or enum.
	CtorDeclBase = 8
)

// ctorOf returns the head constructor of t, or -1 if it has none.
func ctorOf(t *Type) int {
	t = prune(t)
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
