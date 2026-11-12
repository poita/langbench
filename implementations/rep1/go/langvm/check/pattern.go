package check

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/types"
)

// binds collects the bindings a pattern introduces, in order.
type binds struct {
	list  []*types.Local
	names map[string]bool
}

func newBinds() *binds { return &binds{names: map[string]bool{}} }

func (fc *fnCtx) bind(bs *binds, name string, pos diag.Pos, t *types.Type) *types.Local {
	if bs.names[name] {
		fc.fail(diag.DupName, pos)
	}
	bs.names[name] = true
	l := fc.newLocal(name, t, false)
	bs.list = append(bs.list, l)
	return l
}

func (fc *fnCtx) declareBinds(bs *binds) {
	for _, l := range bs.list {
		fc.declare(l)
	}
}

// pattern types p against the (ground) expected type want (section 12.2).
func (fc *fnCtx) pattern(p ast.Pattern, want *types.Type, bs *binds) {
	switch p := p.(type) {
	case *ast.WildPat:
	case *ast.IdentPat:
		if v := fc.identVariant(p.Name); v != nil {
			p.Variant = v
			fc.variantType(p.Pos, v, want)
			return
		}
		p.Local = fc.bind(bs, p.Name, p.Pos, want)
	case *ast.LitPat:
		var t *types.Type
		switch p.Kind {
		case ast.LitFloat:
			fc.fail(diag.BadPattern, p.Pos)
		case ast.LitInt:
			t = types.Int
		case ast.LitStr:
			t = types.Str
		case ast.LitChar:
			t = types.Char
		case ast.LitBool:
			t = types.Bool
		}
		if !types.Equal(t, want) {
			fc.mismatch(p.Pos)
		}
	case *ast.TuplePat:
		w := rs(want)
		if w.Kind != types.KTuple || len(w.Args) != len(p.Elems) {
			fc.mismatch(p.Pos)
		}
		for i, e := range p.Elems {
			fc.pattern(e, w.Args[i], bs)
		}
	case *ast.ListPat:
		w := rs(want)
		if w.Kind != types.KList {
			fc.mismatch(p.Pos)
		}
		for _, e := range p.Elems {
			fc.pattern(e, w.Args[0], bs)
		}
		if p.Rest != nil {
			p.Local = fc.bind(bs, p.Rest.Name, p.Rest.Pos, want)
		}
	case *ast.VariantPat:
		res := fc.resolvePath(p.Path, false)
		if res.kind != resVariant {
			fc.mismatch(p.Pos)
		}
		v := res.variant
		p.Variant = v
		payload := fc.variantType(p.Pos, v, want)
		if len(p.Args) != len(payload) {
			fc.fail(diag.Arity, p.Pos)
		}
		for i, a := range p.Args {
			fc.pattern(a, payload[i], bs)
		}
	case *ast.StructPat:
		decl := fc.c.lookupTypeDecl(fc.mod, p.Path)
		if decl.IsEnum {
			fc.fail(diag.NotStruct, p.Path.Pos)
		}
		w := rs(want)
		if w.Kind != types.KNamed || w.Decl != decl {
			fc.mismatch(p.Pos)
		}
		p.Decl = decl
		seen := map[string]bool{}
		for _, f := range p.Fields {
			if seen[f.Name.Name] {
				fc.fail(diag.DupField, f.Name.Pos)
			}
			seen[f.Name.Name] = true
			f.Index = decl.FieldIndex(f.Name.Name)
			if f.Index < 0 {
				fc.fail(diag.UnknownField, f.Name.Pos)
			}
		}
		if !p.HasRest && len(p.Fields) != len(decl.Fields) {
			fc.fail(diag.MissingField, p.Pos)
		}
		sub := declSubst(decl, w.Args)
		for _, f := range p.Fields {
			ft := types.Subst(decl.Fields[f.Index].Type, sub)
			if f.Pat != nil {
				fc.pattern(f.Pat, ft, bs)
			} else {
				f.Local = fc.bind(bs, f.Name.Name, f.Name.Pos, ft)
			}
		}
	}
}

// variantType checks that want is the enum of v and returns the payload types.
func (fc *fnCtx) variantType(pos diag.Pos, v *types.Variant, want *types.Type) []*types.Type {
	w := rs(want)
	if w.Kind != types.KNamed || w.Decl != v.Decl {
		fc.mismatch(pos)
	}
	sub := declSubst(v.Decl, w.Args)
	out := make([]*types.Type, len(v.Payload))
	for i, t := range v.Payload {
		out[i] = types.Subst(t, sub)
	}
	return out
}

// irrefutable implements section 12.6 on a typed pattern.
func irrefutable(p ast.Pattern) bool {
	switch p := p.(type) {
	case *ast.WildPat:
		return true
	case *ast.IdentPat:
		return p.Variant == nil || len(p.Variant.Decl.Variants) == 1
	case *ast.LitPat:
		return false
	case *ast.TuplePat:
		for _, e := range p.Elems {
			if !irrefutable(e) {
				return false
			}
		}
		return true
	case *ast.ListPat:
		return p.HasRest && len(p.Elems) == 0
	case *ast.StructPat:
		for _, f := range p.Fields {
			if f.Pat != nil && !irrefutable(f.Pat) {
				return false
			}
		}
		return true
	case *ast.VariantPat:
		if len(p.Variant.Decl.Variants) != 1 {
			return false
		}
		for _, a := range p.Args {
			if !irrefutable(a) {
				return false
			}
		}
		return true
	}
	return false
}
