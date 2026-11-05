package check

// satisfies decides whether the (ground) type t satisfies trait tr: the
// built-in traits structurally (SPEC 7), user traits through the impl table
// (SPEC 8.4).
func (c *Checker) satisfies(t *Type, tr *Trait) bool {
	t = prune(t)
	switch tr.Builtin {
	case BEq:
		return c.isEq(t, map[*TypeDecl]bool{})
	case BOrd:
		return c.isOrd(t)
	case BKey:
		return c.isKey(t)
	}
	return c.implements(t, tr)
}

func (c *Checker) isOrd(t *Type) bool {
	t = prune(t)
	switch t.Kind {
	case KInt, KFloat, KBool, KChar, KStr:
		return true
	case KParam:
		return t.Param.hasBound(c.ord)
	}
	return false
}

func (c *Checker) isKey(t *Type) bool {
	t = prune(t)
	switch t.Kind {
	case KInt, KBool, KChar, KStr:
		return true
	case KParam:
		return t.Param.hasBound(c.key)
	}
	return false
}

func (c *Checker) isEq(t *Type, assume map[*TypeDecl]bool) bool {
	t = prune(t)
	switch t.Kind {
	case KInt, KFloat, KBool, KChar, KStr, KUnit:
		return true
	case KList:
		return c.isEq(t.Elems[0], assume)
	case KMap:
		return c.isEq(t.Elems[1], assume)
	case KTuple:
		for _, e := range t.Elems {
			if !c.isEq(e, assume) {
				return false
			}
		}
		return true
	case KFn:
		return false
	case KParam:
		return t.Param.hasBound(c.eq) || t.Param.hasBound(c.key)
	case KNamed:
		d := t.Decl
		if assume[d] {
			return true
		}
		assume[d] = true
		defer delete(assume, d)
		m := declSubst(t)
		if !d.IsEnum {
			for _, f := range d.Fields {
				if !c.isEq(subst(f.Type, m), assume) {
					return false
				}
			}
			return true
		}
		for _, v := range d.Variants {
			for _, p := range v.Payload {
				if !c.isEq(subst(p, m), assume) {
					return false
				}
			}
		}
		return true
	}
	return true // unsolved variable: be permissive
}

// declSubst maps a named type's declaration parameters to its arguments.
func declSubst(t *Type) map[*TypeParam]*Type {
	m := make(map[*TypeParam]*Type, len(t.Elems))
	for i, p := range t.Decl.Params {
		m[p] = t.Elems[i]
	}
	return m
}

// implements decides whether a user trait holds for t (SPEC 8.4).
func (c *Checker) implements(t *Type, tr *Trait) bool {
	t = prune(t)
	if t.Kind == KParam {
		return t.Param.hasBound(tr)
	}
	ctor := ctorOf(t)
	if ctor < 0 {
		return false
	}
	impl := c.impls[implKey{tr.ID, ctor}]
	if impl == nil {
		return false
	}
	m := map[*TypeParam]*Type{}
	switch impl.Head.Kind {
	case KList, KMap, KNamed:
		for i, e := range impl.Head.Elems {
			m[prune(e).Param] = t.Elems[i]
		}
	}
	for _, p := range impl.TParams {
		for _, b := range p.Bounds {
			if !c.satisfies(m[p], b) {
				return false
			}
		}
	}
	return true
}
