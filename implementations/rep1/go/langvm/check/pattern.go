package check

import (
	"langvm/ast"
	"langvm/diag"
)

// pattern types p against t (SPEC 12.2) and declares its bindings in the
// current scope.
func (b *body) pattern(p ast.Pattern, t *Type) {
	names := map[string]bool{}
	b.pat(p, t, names)
}

func (b *body) bind(names map[string]bool, id ast.Ident, t *Type) *Local {
	if names[id.Name] {
		b.fail(diag.DupName, id.Pos)
	}
	names[id.Name] = true
	return b.declare(id.Name, false, t)
}

// lookupPatValue resolves a pattern's constructor name (locals are not
// consulted).
func (b *body) lookupPatValue(mod *ast.Ident, name ast.Ident) any {
	if mod == nil {
		if v, ok := b.mod.Values[name.Name]; ok {
			return v
		}
		if v, ok := b.c.prelude.Values[name.Name]; ok {
			return v
		}
		b.fail(diag.UnknownName, name.Pos)
	}
	return b.qualifiedValue(mod, name)
}

func (b *body) variantPattern(v *Variant, t *Type, pos ast.Pos) *Type {
	t = prune(t)
	if t.Kind != KNamed || t.Decl != v.Enum {
		b.fail(diag.TypeMismatch, pos)
	}
	return t
}

func (b *body) pat(p ast.Pattern, t *Type, names map[string]bool) {
	switch n := p.(type) {
	case *ast.WildPat:
	case *ast.NamePat:
		if n.Mod == nil {
			if v, ok := b.zeroVariant(n.Name.Name); ok {
				n.Var = v
				b.variantPattern(v, t, n.P)
				return
			}
			n.Local = b.bind(names, n.Name, t)
			return
		}
		v, ok := b.lookupPatValue(n.Mod, n.Name).(*Variant)
		if !ok {
			b.fail(diag.TypeMismatch, n.P)
		}
		b.variantPattern(v, t, n.P)
		if len(v.Payload) != 0 {
			b.fail(diag.Arity, n.P)
		}
		n.Var = v
	case *ast.LitPat:
		var want *Type
		switch n.Kind {
		case ast.LitFloat:
			b.fail(diag.BadPattern, n.P)
		case ast.LitInt:
			want = TInt
		case ast.LitStr:
			want = TStr
		case ast.LitChar:
			want = TChar
		default:
			want = TBool
		}
		if prune(t) != want {
			b.fail(diag.TypeMismatch, n.P)
		}
	case *ast.VariantPat:
		v, ok := b.lookupPatValue(n.Mod, n.Name).(*Variant)
		if !ok {
			b.fail(diag.TypeMismatch, n.P)
		}
		tt := b.variantPattern(v, t, n.P)
		if len(n.Args) != len(v.Payload) {
			b.fail(diag.Arity, n.P)
		}
		n.Var = v
		m := declSubst(tt)
		for i, a := range n.Args {
			b.pat(a, subst(v.Payload[i], m), names)
		}
	case *ast.StructPat:
		d := b.structDecl(n.Mod, n.Name, n.P)
		tt := prune(t)
		if tt.Kind != KNamed || tt.Decl != d {
			b.fail(diag.TypeMismatch, n.P)
		}
		n.Decl = d
		seen := map[string]bool{}
		for _, f := range n.Fields {
			if seen[f.Name.Name] {
				b.fail(diag.DupField, f.Name.Pos)
			}
			seen[f.Name.Name] = true
			f.Index = -1
			for j, df := range d.Fields {
				if df.Name == f.Name.Name {
					f.Index = j
					break
				}
			}
			if f.Index < 0 {
				b.fail(diag.UnknownField, f.Name.Pos)
			}
		}
		if !n.Rest && len(n.Fields) != len(d.Fields) {
			b.fail(diag.MissingField, n.P)
		}
		m := declSubst(tt)
		for _, f := range n.Fields {
			ft := subst(d.Fields[f.Index].Type, m)
			if f.Pat == nil {
				f.Local = b.bind(names, f.Name, ft)
			} else {
				b.pat(f.Pat, ft, names)
			}
		}
	case *ast.TuplePat:
		tt := prune(t)
		if tt.Kind != KTuple || len(tt.Elems) != len(n.Elems) {
			b.fail(diag.TypeMismatch, n.P)
		}
		for i, e := range n.Elems {
			b.pat(e, tt.Elems[i], names)
		}
	case *ast.ListPat:
		tt := prune(t)
		if tt.Kind != KList {
			b.fail(diag.TypeMismatch, n.P)
		}
		for _, e := range n.Elems {
			b.pat(e, tt.Elems[0], names)
		}
		if n.RestName != nil {
			n.RestLocal = b.bind(names, *n.RestName, tt)
		}
	}
}

// zeroVariant reports whether name resolves, among module items and the
// prelude, to an enum variant with no payload.
func (b *body) zeroVariant(name string) (*Variant, bool) {
	var v any
	if x, ok := b.mod.Values[name]; ok {
		v = x
	} else if x, ok := b.c.prelude.Values[name]; ok {
		v = x
	}
	if vr, ok := v.(*Variant); ok && len(vr.Payload) == 0 {
		return vr, true
	}
	return nil, false
}

// irrefutable implements SPEC 12.6 on a typed pattern.
func irrefutable(p ast.Pattern) bool {
	switch n := p.(type) {
	case *ast.WildPat:
		return true
	case *ast.NamePat:
		if n.Var != nil {
			v := n.Var.(*Variant)
			return len(v.Enum.Variants) == 1
		}
		return true
	case *ast.LitPat:
		return false
	case *ast.VariantPat:
		v := n.Var.(*Variant)
		if len(v.Enum.Variants) != 1 {
			return false
		}
		for _, a := range n.Args {
			if !irrefutable(a) {
				return false
			}
		}
		return true
	case *ast.StructPat:
		for _, f := range n.Fields {
			if f.Pat != nil && !irrefutable(f.Pat) {
				return false
			}
		}
		return true
	case *ast.TuplePat:
		for _, e := range n.Elems {
			if !irrefutable(e) {
				return false
			}
		}
		return true
	case *ast.ListPat:
		return len(n.Elems) == 0 && n.HasRest
	}
	return false
}
