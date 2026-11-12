package check

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/types"
)

// A lowered pattern for the usefulness algorithm of section 12.4.
type ctorKind uint8

const (
	ckVariant ctorKind = iota
	ckBool
	ckInt
	ckChar
	ckStr
	ckTuple
	ckStruct
)

type ctor struct {
	kind ctorKind
	n    int64
	s    string
}

type lp struct {
	wild   bool
	isList bool
	open   bool // list pattern with a rest
	c      ctor
	args   []*lp
}

var wildLP = &lp{wild: true}

func lower(p ast.Pattern) *lp {
	switch p := p.(type) {
	case *ast.IdentPat:
		if p.Variant != nil {
			return &lp{c: ctor{kind: ckVariant, n: int64(p.Variant.Index)}}
		}
		return wildLP
	case *ast.VariantPat:
		args := make([]*lp, len(p.Args))
		for i, a := range p.Args {
			args[i] = lower(a)
		}
		return &lp{c: ctor{kind: ckVariant, n: int64(p.Variant.Index)}, args: args}
	case *ast.LitPat:
		switch p.Kind {
		case ast.LitInt:
			return &lp{c: ctor{kind: ckInt, n: p.Int}}
		case ast.LitChar:
			return &lp{c: ctor{kind: ckChar, n: p.Int}}
		case ast.LitBool:
			return &lp{c: ctor{kind: ckBool, n: p.Int}}
		case ast.LitStr:
			return &lp{c: ctor{kind: ckStr, s: string(p.Str)}}
		}
		return wildLP
	case *ast.TuplePat:
		args := make([]*lp, len(p.Elems))
		for i, a := range p.Elems {
			args[i] = lower(a)
		}
		return &lp{c: ctor{kind: ckTuple}, args: args}
	case *ast.StructPat:
		args := make([]*lp, len(p.Decl.Fields))
		for i := range args {
			args[i] = wildLP
		}
		for _, f := range p.Fields {
			if f.Pat != nil {
				args[f.Index] = lower(f.Pat)
			}
		}
		return &lp{c: ctor{kind: ckStruct}, args: args}
	case *ast.ListPat:
		args := make([]*lp, len(p.Elems))
		for i, a := range p.Elems {
			args[i] = lower(a)
		}
		return &lp{isList: true, open: p.HasRest, args: args}
	}
	return wildLP
}

type row []*lp

func wilds(n int) []*lp {
	out := make([]*lp, n)
	for i := range out {
		out[i] = wildLP
	}
	return out
}

func concat(a []*lp, b []*lp) []*lp {
	out := make([]*lp, 0, len(a)+len(b))
	out = append(out, a...)
	out = append(out, b...)
	return out
}

func concatT(a []*types.Type, b []*types.Type) []*types.Type {
	out := make([]*types.Type, 0, len(a)+len(b))
	out = append(out, a...)
	out = append(out, b...)
	return out
}

// ctorArgTypes returns the column types a constructor expands to.
func ctorArgTypes(t *types.Type, c ctor, arity int) []*types.Type {
	switch c.kind {
	case ckTuple:
		return t.Args
	case ckStruct:
		sub := declSubst(t.Decl, t.Args)
		out := make([]*types.Type, len(t.Decl.Fields))
		for i, f := range t.Decl.Fields {
			out[i] = types.Subst(f.Type, sub)
		}
		return out
	case ckVariant:
		v := t.Decl.Variants[c.n]
		sub := declSubst(t.Decl, t.Args)
		out := make([]*types.Type, len(v.Payload))
		for i, p := range v.Payload {
			out[i] = types.Subst(p, sub)
		}
		return out
	}
	return nil
}

// allCtors enumerates the constructors of a finite type, or reports false.
func allCtors(t *types.Type) ([]ctor, bool) {
	switch t.Kind {
	case types.KBool:
		return []ctor{{kind: ckBool, n: 0}, {kind: ckBool, n: 1}}, true
	case types.KTuple:
		return []ctor{{kind: ckTuple}}, true
	case types.KNamed:
		if t.Decl.IsEnum {
			cs := make([]ctor, len(t.Decl.Variants))
			for i := range cs {
				cs[i] = ctor{kind: ckVariant, n: int64(i)}
			}
			return cs, true
		}
		return []ctor{{kind: ckStruct}}, true
	}
	return nil, false
}

func specialize(rows []row, c ctor, arity int) []row {
	var out []row
	for _, r := range rows {
		p := r[0]
		switch {
		case p.wild:
			out = append(out, concat(wilds(arity), r[1:]))
		case !p.isList && p.c == c:
			out = append(out, concat(p.args, r[1:]))
		}
	}
	return out
}

func specializeList(rows []row, k int) []row {
	var out []row
	for _, r := range rows {
		if nr, ok := specListRow(r, k); ok {
			out = append(out, nr)
		}
	}
	return out
}

func specListRow(r row, k int) (row, bool) {
	p := r[0]
	if p.wild {
		return concat(wilds(k), r[1:]), true
	}
	n := len(p.args)
	if p.open {
		if n > k {
			return nil, false
		}
		return concat(concat(p.args, wilds(k-n)), r[1:]), true
	}
	if n != k {
		return nil, false
	}
	return concat(p.args, r[1:]), true
}

// useful reports whether row q is useful against rows (section 12.4).
func useful(rows []row, q row, tys []*types.Type) bool {
	if len(q) == 0 {
		return len(rows) == 0
	}
	t := types.Resolve(tys[0])
	if t.Kind == types.KList {
		lmax := 0
		for _, r := range rows {
			if !r[0].wild && len(r[0].args) > lmax {
				lmax = len(r[0].args)
			}
		}
		if !q[0].wild && len(q[0].args) > lmax {
			lmax = len(q[0].args)
		}
		for k := 0; k <= lmax+1; k++ {
			if !q[0].wild {
				n := len(q[0].args)
				if q[0].open {
					if k < n {
						continue
					}
				} else if k != n {
					continue
				}
			}
			q2, ok := specListRow(q, k)
			if !ok {
				continue
			}
			elems := make([]*types.Type, k)
			for i := range elems {
				elems[i] = t.Args[0]
			}
			if useful(specializeList(rows, k), q2, concatT(elems, tys[1:])) {
				return true
			}
		}
		return false
	}
	if !q[0].wild {
		c := q[0].c
		arity := len(q[0].args)
		return useful(specialize(rows, c, arity), concat(q[0].args, q[1:]),
			concatT(ctorArgTypes(t, c, arity), tys[1:]))
	}
	all, finite := allCtors(t)
	if finite {
		used := map[ctor]bool{}
		for _, r := range rows {
			if !r[0].wild && !r[0].isList {
				used[r[0].c] = true
			}
		}
		if len(used) == len(all) {
			for _, c := range all {
				ats := ctorArgTypes(t, c, 0)
				arity := len(ats)
				if useful(specialize(rows, c, arity), concat(wilds(arity), q[1:]), concatT(ats, tys[1:])) {
					return true
				}
			}
			return false
		}
	}
	var def []row
	for _, r := range rows {
		if r[0].wild {
			def = append(def, r[1:])
		}
	}
	return useful(def, q[1:], tys[1:])
}

// checkExhaustive performs the reachability and exhaustiveness checks of a
// typed match (steps 4 and 5 of section 10.12).
func (fc *fnCtx) checkExhaustive(m *ast.MatchExpr, s *types.Type) {
	tys := []*types.Type{s}
	var rows []row
	for _, arm := range m.Arms {
		q := lower(arm.Pat)
		if !useful(rows, row{q}, tys) {
			fc.fail(diag.Unreachable, arm.Pat.PatPos())
		}
		if arm.Guard == nil {
			rows = append(rows, row{q})
		}
	}
	if useful(rows, row{wildLP}, tys) {
		fc.fail(diag.NonExhaustive, m.Pos)
	}
}
