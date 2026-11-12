package check

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/types"
)

// tctx is the context in which written types are resolved: the module whose
// text contains them (nil for the prelude), the generic parameters in scope
// and the meaning of Self (nil outside traits and impls).
type tctx struct {
	mod     *modInfo
	tparams map[string]*types.TypeParam
	self    *types.Type
}

var primTypes = map[string]*types.Type{
	"Int": types.Int, "Float": types.Float, "Bool": types.Bool,
	"Char": types.Char, "Str": types.Str, "Unit": types.Unit,
}

// lookupQualifiedType resolves `m::N` in the types namespace.
func (c *checker) lookupQualifiedType(cur *modInfo, qual, name ast.Ident) *types.Decl {
	var im *modInfo
	if cur != nil {
		im = cur.imports[qual.Name]
	}
	if im == nil {
		c.fail(diag.UnknownModule, qual.Pos)
	}
	d, ok := im.typesNS[name.Name]
	if !ok {
		c.fail(diag.UnknownType, name.Pos)
	}
	if !d.Pub && im != cur {
		c.fail(diag.NotPublic, name.Pos)
	}
	return d
}

// lookupTypeDecl resolves a type name for a struct literal or struct pattern:
// module types, then the prelude's Option and Result.
func (c *checker) lookupTypeDecl(cur *modInfo, p *ast.PathExpr) *types.Decl {
	if p.Qual != nil {
		return c.lookupQualifiedType(cur, *p.Qual, p.Name)
	}
	if cur != nil {
		if d, ok := cur.typesNS[p.Name.Name]; ok {
			return d
		}
	}
	switch p.Name.Name {
	case "Option":
		return c.option
	case "Result":
		return c.result
	}
	c.fail(diag.UnknownType, p.Name.Pos)
	return nil
}

// resolveType resolves a written type to a semantic type (section 6.1).
func (c *checker) resolveType(ctx *tctx, t ast.Type) *types.Type {
	switch t := t.(type) {
	case *ast.ListType:
		return types.NewList(c.resolveType(ctx, t.Elem))
	case *ast.MapType:
		k := c.resolveType(ctx, t.K)
		v := c.resolveType(ctx, t.V)
		if !c.isKey(k) {
			c.fail(diag.BadKeyType, t.Pos)
		}
		return types.NewMap(k, v)
	case *ast.TupleType:
		if len(t.Elems) > 8 {
			c.fail(diag.BadArity, t.Pos)
		}
		parts := make([]*types.Type, len(t.Elems))
		for i, e := range t.Elems {
			parts[i] = c.resolveType(ctx, e)
		}
		return types.NewTuple(parts)
	case *ast.FnType:
		if len(t.Params) > 16 {
			c.fail(diag.BadArity, t.Pos)
		}
		ps := make([]*types.Type, len(t.Params))
		for i, e := range t.Params {
			ps[i] = c.resolveType(ctx, e)
		}
		ret := types.Unit
		if t.Ret != nil {
			ret = c.resolveType(ctx, t.Ret)
		}
		return types.NewFunc(ps, ret)
	case *ast.PathType:
		return c.resolvePathType(ctx, t)
	}
	panic("unknown type node")
}

func (c *checker) resolveArgs(ctx *tctx, args []ast.Type) []*types.Type {
	out := make([]*types.Type, len(args))
	for i, a := range args {
		out[i] = c.resolveType(ctx, a)
	}
	return out
}

func (c *checker) resolvePathType(ctx *tctx, t *ast.PathType) *types.Type {
	var decl *types.Decl
	if t.Qual != nil {
		decl = c.lookupQualifiedType(ctx.mod, *t.Qual, t.Name)
	} else {
		name := t.Name.Name
		if p, ok := ctx.tparams[name]; ok {
			if t.HasArgs {
				c.fail(diag.ArityType, t.Pos)
			}
			return types.NewParam(p)
		}
		if name == "Self" {
			if ctx.self == nil {
				c.fail(diag.SelfOutside, t.Pos)
			}
			if t.HasArgs {
				c.fail(diag.ArityType, t.Pos)
			}
			return ctx.self
		}
		if pt, ok := primTypes[name]; ok {
			if t.HasArgs {
				c.fail(diag.ArityType, t.Pos)
			}
			return pt
		}
		if ctx.mod != nil {
			if d, ok := ctx.mod.typesNS[name]; ok {
				decl = d
			}
		}
		if decl == nil {
			switch name {
			case "Option":
				decl = c.option
			case "Result":
				decl = c.result
			default:
				c.fail(diag.UnknownType, t.Name.Pos)
			}
		}
	}
	if len(t.Args) != len(decl.TParams) {
		c.fail(diag.ArityType, t.Pos)
	}
	return types.NewNamed(decl, c.resolveArgs(ctx, t.Args))
}

// resolveTrait resolves a trait reference written in module m (nil for the
// prelude).
func (c *checker) resolveTrait(m *modInfo, r *ast.TraitRef) *types.Trait {
	if r.Qual != nil {
		var im *modInfo
		if m != nil {
			im = m.imports[r.Qual.Name]
		}
		if im == nil {
			c.fail(diag.UnknownModule, r.Qual.Pos)
		}
		t, ok := im.traitsNS[r.Name.Name]
		if !ok {
			c.fail(diag.UnknownTrait, r.Name.Pos)
		}
		if !t.Pub && im != m {
			c.fail(diag.NotPublic, r.Name.Pos)
		}
		return t
	}
	if m != nil {
		if t, ok := m.traitsNS[r.Name.Name]; ok {
			return t
		}
	}
	switch r.Name.Name {
	case "Eq":
		return c.eqTrait
	case "Ord":
		return c.ordTrait
	case "Key":
		return c.keyTrait
	}
	c.fail(diag.UnknownTrait, r.Name.Pos)
	return nil
}
