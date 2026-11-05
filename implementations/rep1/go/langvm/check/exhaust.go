package check

import (
	"langvm/ast"
	"langvm/diag"
)

// Pattern-matrix analysis: the usefulness algorithm of SPEC 12.4.

type ctorKey struct {
	tag uint8
	n   int64
	s   string
}

const (
	tagSingle uint8 = iota
	tagBool
	tagVar
	tagInt
	tagChar
	tagStr
)

type spat struct {
	wild bool
	ctor ctorKey
	sub  []*spat
	list bool // list pattern: sub holds the element patterns
	open bool // list pattern with a `..` rest
}

var wildPat = &spat{wild: true}

type ctorInfo struct {
	key ctorKey
	sub []*Type
}

// ctorSet returns the constructors of a finite type; ok is false for types
// with an infinite constructor set.
func ctorSet(t *Type) (cs []ctorInfo, ok bool) {
	t = prune(t)
	switch t.Kind {
	case KBool:
		return []ctorInfo{{key: ctorKey{tag: tagBool, n: 1}}, {key: ctorKey{tag: tagBool, n: 0}}}, true
	case KUnit:
		return []ctorInfo{{key: ctorKey{tag: tagSingle}}}, true
	case KTuple:
		return []ctorInfo{{key: ctorKey{tag: tagSingle}, sub: t.Elems}}, true
	case KNamed:
		m := declSubst(t)
		if !t.Decl.IsEnum {
			sub := make([]*Type, len(t.Decl.Fields))
			for i, f := range t.Decl.Fields {
				sub[i] = subst(f.Type, m)
			}
			return []ctorInfo{{key: ctorKey{tag: tagSingle}, sub: sub}}, true
		}
		out := make([]ctorInfo, len(t.Decl.Variants))
		for i, v := range t.Decl.Variants {
			sub := make([]*Type, len(v.Payload))
			for j, p := range v.Payload {
				sub[j] = subst(p, m)
			}
			out[i] = ctorInfo{key: ctorKey{tag: tagVar, n: int64(i)}, sub: sub}
		}
		return out, true
	}
	return nil, false
}

// ctorSub returns the component types of constructor key for type t.
func ctorSub(t *Type, key ctorKey) []*Type {
	if cs, ok := ctorSet(t); ok {
		for _, c := range cs {
			if c.key == key {
				return c.sub
			}
		}
	}
	return nil
}

func conv(p ast.Pattern) *spat {
	switch n := p.(type) {
	case *ast.WildPat:
		return wildPat
	case *ast.NamePat:
		if n.Var != nil {
			return &spat{ctor: ctorKey{tag: tagVar, n: int64(n.Var.(*Variant).Index)}}
		}
		return wildPat
	case *ast.LitPat:
		switch n.Kind {
		case ast.LitInt:
			v := n.Int
			if n.Neg {
				v = -v
			}
			return &spat{ctor: ctorKey{tag: tagInt, n: v}}
		case ast.LitChar:
			return &spat{ctor: ctorKey{tag: tagChar, n: n.Int}}
		case ast.LitStr:
			return &spat{ctor: ctorKey{tag: tagStr, s: string(n.Str)}}
		default:
			v := int64(0)
			if n.Bool {
				v = 1
			}
			return &spat{ctor: ctorKey{tag: tagBool, n: v}}
		}
	case *ast.VariantPat:
		sp := &spat{ctor: ctorKey{tag: tagVar, n: int64(n.Var.(*Variant).Index)}}
		for _, a := range n.Args {
			sp.sub = append(sp.sub, conv(a))
		}
		return sp
	case *ast.StructPat:
		d := n.Decl.(*TypeDecl)
		sp := &spat{ctor: ctorKey{tag: tagSingle}, sub: make([]*spat, len(d.Fields))}
		for i := range sp.sub {
			sp.sub[i] = wildPat
		}
		for _, f := range n.Fields {
			if f.Pat != nil {
				sp.sub[f.Index] = conv(f.Pat)
			}
		}
		return sp
	case *ast.TuplePat:
		sp := &spat{ctor: ctorKey{tag: tagSingle}}
		for _, e := range n.Elems {
			sp.sub = append(sp.sub, conv(e))
		}
		return sp
	case *ast.ListPat:
		sp := &spat{list: true, open: n.HasRest}
		for _, e := range n.Elems {
			sp.sub = append(sp.sub, conv(e))
		}
		return sp
	}
	return wildPat
}

func wilds(k int) []*spat {
	out := make([]*spat, k)
	for i := range out {
		out[i] = wildPat
	}
	return out
}

// specialize applies S(c, row) of arity k; ok is false if the row is dropped.
func specialize(row []*spat, key ctorKey, k int) ([]*spat, bool) {
	first := row[0]
	var out []*spat
	switch {
	case first.wild:
		out = append(wilds(k), row[1:]...)
	case first.ctor == key:
		out = append(append([]*spat{}, first.sub...), row[1:]...)
	default:
		return nil, false
	}
	return out, true
}

func specList(row []*spat, k int) ([]*spat, bool) {
	first := row[0]
	switch {
	case first.wild:
		return append(wilds(k), row[1:]...), true
	case !first.open && len(first.sub) == k:
		return append(append([]*spat{}, first.sub...), row[1:]...), true
	case first.open && len(first.sub) <= k:
		out := append([]*spat{}, first.sub...)
		out = append(out, wilds(k-len(first.sub))...)
		return append(out, row[1:]...), true
	}
	return nil, false
}

func repeatType(t *Type, k int) []*Type {
	out := make([]*Type, k)
	for i := range out {
		out[i] = t
	}
	return out
}

// useful computes U(rows, q) over columns of the given types.
func useful(rows [][]*spat, q []*spat, tys []*Type) bool {
	if len(q) == 0 {
		return len(rows) == 0
	}
	t := prune(tys[0])
	rest := tys[1:]
	if t.Kind == KList {
		lmax := 0
		for _, r := range rows {
			if r[0].list && len(r[0].sub) > lmax {
				lmax = len(r[0].sub)
			}
		}
		if q[0].list && len(q[0].sub) > lmax {
			lmax = len(q[0].sub)
		}
		for k := 0; k <= lmax+1; k++ {
			if !q[0].wild {
				if q[0].open {
					if k < len(q[0].sub) {
						continue
					}
				} else if k != len(q[0].sub) {
					continue
				}
			}
			var nrows [][]*spat
			for _, r := range rows {
				if sr, ok := specList(r, k); ok {
					nrows = append(nrows, sr)
				}
			}
			nq, _ := specList(q, k)
			ntys := append(repeatType(t.Elems[0], k), rest...)
			if useful(nrows, nq, ntys) {
				return true
			}
		}
		return false
	}
	spec := func(key ctorKey, sub []*Type) bool {
		k := len(sub)
		var nrows [][]*spat
		for _, r := range rows {
			if sr, ok := specialize(r, key, k); ok {
				nrows = append(nrows, sr)
			}
		}
		nq, ok := specialize(q, key, k)
		if !ok {
			return false
		}
		return useful(nrows, nq, append(append([]*Type{}, sub...), rest...))
	}
	if !q[0].wild {
		key := q[0].ctor
		return spec(key, ctorSub(t, key))
	}
	if cs, finite := ctorSet(t); finite {
		used := map[ctorKey]bool{}
		for _, r := range rows {
			if !r[0].wild {
				used[r[0].ctor] = true
			}
		}
		covered := true
		for _, c := range cs {
			if !used[c.key] {
				covered = false
				break
			}
		}
		if covered {
			for _, c := range cs {
				if spec(c.key, c.sub) {
					return true
				}
			}
			return false
		}
	}
	// default matrix
	var nrows [][]*spat
	for _, r := range rows {
		if r[0].wild {
			nrows = append(nrows, r[1:])
		}
	}
	return useful(nrows, q[1:], rest)
}

// matchAnalysis performs the reachability and exhaustiveness checks of a
// match (SPEC 10.12 steps 4 and 5).
func (b *body) matchAnalysis(n *ast.MatchExpr, scrut *Type) {
	st := zonk(scrut)
	tys := []*Type{st}
	var unguarded [][]*spat
	for _, arm := range n.Arms {
		q := conv(arm.Pat)
		if !useful(unguarded, []*spat{q}, tys) {
			b.fail(diag.Unreachable, arm.Pat.PatPos())
		}
		if arm.Guard == nil {
			unguarded = append(unguarded, []*spat{q})
		}
	}
	if useful(unguarded, []*spat{wildPat}, tys) {
		b.fail(diag.NonExhaustive, n.P)
	}
}
