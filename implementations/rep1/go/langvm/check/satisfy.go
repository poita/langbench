package check

import "langvm/types"

// isEq implements section 7.1.
func (c *checker) isEq(t *types.Type) bool {
	return c.eqRec(t, map[*types.Decl]bool{})
}

func (c *checker) eqRec(t *types.Type, assumed map[*types.Decl]bool) bool {
	t = types.Resolve(t)
	switch t.Kind {
	case types.KInt, types.KFloat, types.KBool, types.KChar, types.KStr, types.KUnit:
		return true
	case types.KList:
		return c.eqRec(t.Args[0], assumed)
	case types.KMap:
		return c.eqRec(t.Args[1], assumed)
	case types.KTuple:
		for _, a := range t.Args {
			if !c.eqRec(a, assumed) {
				return false
			}
		}
		return true
	case types.KFunc, types.KVar:
		return false
	case types.KParam:
		return t.Param.HasBuiltin(types.TraitEq) || t.Param.HasBuiltin(types.TraitKey)
	case types.KNamed:
		d := t.Decl
		if assumed[d] {
			return true
		}
		assumed[d] = true
		defer delete(assumed, d)
		sub := map[*types.TypeParam]*types.Type{}
		for i, p := range d.TParams {
			sub[p] = t.Args[i]
		}
		if d.IsEnum {
			for _, v := range d.Variants {
				for _, pt := range v.Payload {
					if !c.eqRec(types.Subst(pt, sub), assumed) {
						return false
					}
				}
			}
			return true
		}
		for _, f := range d.Fields {
			if !c.eqRec(types.Subst(f.Type, sub), assumed) {
				return false
			}
		}
		return true
	}
	return false
}

// isOrd implements section 7.2.
func (c *checker) isOrd(t *types.Type) bool {
	t = types.Resolve(t)
	switch t.Kind {
	case types.KInt, types.KFloat, types.KBool, types.KChar, types.KStr:
		return true
	case types.KParam:
		return t.Param.HasBuiltin(types.TraitOrd)
	}
	return false
}

// isKey implements section 7.3.
func (c *checker) isKey(t *types.Type) bool {
	t = types.Resolve(t)
	switch t.Kind {
	case types.KInt, types.KBool, types.KChar, types.KStr:
		return true
	case types.KParam:
		return t.Param.HasBuiltin(types.TraitKey)
	}
	return false
}

// holds reports whether the (ground) type t satisfies the bound tr.
func (c *checker) holds(t *types.Type, tr *types.Trait) bool {
	t = types.Resolve(t)
	switch tr.Builtin {
	case types.TraitEq:
		return c.isEq(t)
	case types.TraitOrd:
		return c.isOrd(t)
	case types.TraitKey:
		return c.isKey(t)
	}
	if t.Kind == types.KParam {
		return t.Param.HasBound(tr)
	}
	ctor := t.Ctor()
	if ctor < 0 {
		return false
	}
	impl := c.impls[implKey{tr, ctor}]
	if impl == nil {
		return false
	}
	bind := map[*types.TypeParam]*types.Type{}
	switch impl.Head.Kind {
	case types.KList, types.KMap, types.KNamed:
		for i, a := range impl.Head.Args {
			bind[types.Resolve(a).Param] = t.Args[i]
		}
	}
	for _, p := range impl.TParams {
		for _, b := range p.Bounds {
			if !c.holds(bind[p], b) {
				return false
			}
		}
	}
	return true
}
