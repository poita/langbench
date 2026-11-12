// Package check resolves names, checks types, patterns and exhaustiveness for
// a parsed Vellum program, following SPEC.md sections 5 to 13. It annotates
// the syntax tree in place with the objects each node resolves to.
package check

import (
	"sort"

	"langvm/ast"
	"langvm/builtins"
	"langvm/diag"
	"langvm/lexer"
	"langvm/parser"
	"langvm/types"
)

// Program is the result of a successful check.
type Program struct {
	Modules  []*ast.Module
	Decls    []*types.Decl  // indexed by Decl.ID
	Traits   []*types.Trait // indexed by Trait.ID
	Impls    []*types.Impl
	Builtins []*types.Func // indexed by built-in id
	Main     *types.Func
	Option   *types.Decl
	Result   *types.Decl
}

// bail is the panic payload carrying the first diagnostic.
type bail struct{ err *diag.Error }

type valEntry struct {
	fn      *types.Func
	variant *types.Variant
}

type modInfo struct {
	name     string
	tmod     *types.Module
	ast      *ast.Module
	typesNS  map[string]*types.Decl
	traitsNS map[string]*types.Trait
	valuesNS map[string]valEntry
	imports  map[string]*modInfo
	traits   []*types.Trait // declared traits in source order
}

type implKey struct {
	trait *types.Trait
	ctor  int
}

type checker struct {
	mods   []*modInfo
	byName map[string]*modInfo

	decls    []*types.Decl
	traits   []*types.Trait
	impls    map[implKey]*types.Impl
	implList []*types.Impl

	option, result              *types.Decl
	eqTrait, ordTrait, keyTrait *types.Trait
	preludeValues               map[string]valEntry
	builtinFuncs                []*types.Func

	varScopes [][]*types.Type
	nextVar   int
}

func (c *checker) fail(kind diag.Kind, pos diag.Pos) {
	panic(bail{diag.New(kind, pos)})
}

// Check type-checks the parsed modules (in stream order). On failure it
// returns the first diagnostic in the order of SPEC.md section 13.2.
func Check(mods []*ast.Module) (prog *Program, err *diag.Error) {
	c := &checker{byName: map[string]*modInfo{}, impls: map[implKey]*types.Impl{}}
	defer func() {
		if r := recover(); r != nil {
			if b, ok := r.(bail); ok {
				prog, err = nil, b.err
				return
			}
			panic(r)
		}
	}()
	c.initPrelude()
	for i, m := range mods {
		mi := &modInfo{
			name: m.Name, tmod: &types.Module{Name: m.Name, Index: i}, ast: m,
			typesNS: map[string]*types.Decl{}, traitsNS: map[string]*types.Trait{},
			valuesNS: map[string]valEntry{}, imports: map[string]*modInfo{},
		}
		c.mods = append(c.mods, mi)
		c.byName[m.Name] = mi
	}
	c.declare()
	c.imports()
	c.internalDups()
	c.signatures()
	c.checkImpls()
	main := c.entryPoint()
	c.bodies()
	p := &Program{Modules: mods, Decls: c.decls, Traits: c.traits, Impls: c.implList,
		Builtins: c.builtinFuncs, Main: main, Option: c.option, Result: c.result}
	return p, nil
}

// ---------------------------------------------------------------- prelude

func (c *checker) newDecl(name string, mod *types.Module, pub, isEnum bool) *types.Decl {
	d := &types.Decl{ID: len(c.decls), Name: name, Module: mod, Pub: pub, IsEnum: isEnum}
	c.decls = append(c.decls, d)
	return d
}

func (c *checker) newTrait(name string, mod *types.Module, pub bool) *types.Trait {
	t := &types.Trait{ID: len(c.traits), Name: name, Module: mod, Pub: pub}
	t.SelfParam = &types.TypeParam{Name: "Self", Bounds: []*types.Trait{t}}
	c.traits = append(c.traits, t)
	return t
}

func (c *checker) initPrelude() {
	c.preludeValues = map[string]valEntry{}
	// Option and Result are decls 0 and 1.
	tp := &types.TypeParam{Name: "T"}
	c.option = c.newDecl("Option", nil, true, true)
	c.option.TParams = []*types.TypeParam{tp}
	c.option.Variants = []*types.Variant{
		{Name: "Some", Index: 0, Decl: c.option, Payload: []*types.Type{types.NewParam(tp)}},
		{Name: "None", Index: 1, Decl: c.option},
	}
	rt := &types.TypeParam{Name: "T"}
	re := &types.TypeParam{Name: "E"}
	c.result = c.newDecl("Result", nil, true, true)
	c.result.TParams = []*types.TypeParam{rt, re}
	c.result.Variants = []*types.Variant{
		{Name: "Ok", Index: 0, Decl: c.result, Payload: []*types.Type{types.NewParam(rt)}},
		{Name: "Err", Index: 1, Decl: c.result, Payload: []*types.Type{types.NewParam(re)}},
	}
	for _, d := range []*types.Decl{c.option, c.result} {
		for _, v := range d.Variants {
			c.preludeValues[v.Name] = valEntry{variant: v}
		}
	}
	c.eqTrait = c.newTrait("Eq", nil, true)
	c.eqTrait.Builtin = types.TraitEq
	c.ordTrait = c.newTrait("Ord", nil, true)
	c.ordTrait.Builtin = types.TraitOrd
	c.keyTrait = c.newTrait("Key", nil, true)
	c.keyTrait.Builtin = types.TraitKey
	for _, t := range []*types.Trait{c.eqTrait, c.ordTrait, c.keyTrait} {
		t.SelfParam.Bounds = nil
	}

	// Built-in functions: parse their signatures.
	for id, spec := range builtins.All {
		toks, lerr := lexer.Lex([]string{spec.Sig + " {}"})
		if lerr != nil {
			panic("builtin signature does not lex: " + spec.Sig)
		}
		m, perr := parser.Parse("builtins", toks)
		if perr != nil || len(m.Items) != 1 {
			panic("builtin signature does not parse: " + spec.Sig)
		}
		fd := m.Items[0].(*ast.FnDecl)
		f := &types.Func{Name: spec.Name, Pub: true, Builtin: id}
		ctx := &tctx{tparams: map[string]*types.TypeParam{}}
		f.TParams = c.makeTParams(fd.Generics, ctx)
		c.resolveBounds(fd.Generics, f.TParams, ctx)
		for _, p := range fd.Params {
			f.Params = append(f.Params, c.resolveType(ctx, p.Type))
		}
		f.Ret = types.Unit
		if fd.Ret != nil {
			f.Ret = c.resolveType(ctx, fd.Ret)
		}
		c.builtinFuncs = append(c.builtinFuncs, f)
		c.preludeValues[spec.Name] = valEntry{fn: f}
	}
}

// makeTParams creates the TypeParams of a generics list and registers them in
// ctx (a later parameter of the same name replaces an earlier one; duplicates
// are reported by internalDups before anything depends on this).
func (c *checker) makeTParams(gs []*ast.GenParam, ctx *tctx) []*types.TypeParam {
	var ps []*types.TypeParam
	for _, g := range gs {
		p := &types.TypeParam{Name: g.Name.Name}
		ps = append(ps, p)
		if ctx != nil {
			ctx.tparams[g.Name.Name] = p
		}
	}
	return ps
}

func (c *checker) resolveBounds(gs []*ast.GenParam, ps []*types.TypeParam, ctx *tctx) {
	for i, g := range gs {
		for _, b := range g.Bounds {
			ps[i].Bounds = append(ps[i].Bounds, c.resolveTrait(ctx.mod, b))
		}
	}
}

// ---------------------------------------------------------------- pass 3.1

var reserved = map[string]bool{
	"Int": true, "Float": true, "Bool": true, "Char": true, "Str": true,
	"Unit": true, "Self": true,
}

func (c *checker) declare() {
	for _, m := range c.mods {
		for _, it := range m.ast.Items {
			switch d := it.(type) {
			case *ast.StructDecl:
				if reserved[d.Name.Name] {
					c.fail(diag.ReservedName, d.Name.Pos)
				}
				decl := c.newDecl(d.Name.Name, m.tmod, d.Pub, false)
				d.Decl = decl
				decl.TParams = c.makeTParams(d.Generics, nil)
				if _, dup := m.typesNS[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				m.typesNS[d.Name.Name] = decl
			case *ast.EnumDecl:
				if reserved[d.Name.Name] {
					c.fail(diag.ReservedName, d.Name.Pos)
				}
				decl := c.newDecl(d.Name.Name, m.tmod, d.Pub, true)
				d.Decl = decl
				decl.TParams = c.makeTParams(d.Generics, nil)
				if _, dup := m.typesNS[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				m.typesNS[d.Name.Name] = decl
				for i, v := range d.Variants {
					vr := &types.Variant{Name: v.Name.Name, Index: i, Decl: decl}
					decl.Variants = append(decl.Variants, vr)
					if _, dup := m.valuesNS[v.Name.Name]; dup {
						c.fail(diag.DupName, v.Name.Pos)
					}
					m.valuesNS[v.Name.Name] = valEntry{variant: vr}
				}
			case *ast.TraitDecl:
				if reserved[d.Name.Name] {
					c.fail(diag.ReservedName, d.Name.Pos)
				}
				tr := c.newTrait(d.Name.Name, m.tmod, d.Pub)
				d.Trait = tr
				if _, dup := m.traitsNS[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				m.traitsNS[d.Name.Name] = tr
				m.traits = append(m.traits, tr)
			case *ast.FnDecl:
				f := &types.Func{Name: d.Name.Name, Module: m.tmod, Pub: d.Pub, Builtin: -1}
				d.Func = f
				f.TParams = c.makeTParams(d.Generics, nil)
				if _, dup := m.valuesNS[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				m.valuesNS[d.Name.Name] = valEntry{fn: f}
			}
		}
	}
}

// ---------------------------------------------------------------- pass 3.2

func (c *checker) imports() {
	for _, m := range c.mods {
		for _, it := range m.ast.Items {
			u, ok := it.(*ast.UseDecl)
			if !ok {
				continue
			}
			target := c.byName[u.Name.Name]
			if target == nil {
				c.fail(diag.UnknownModule, u.Name.Pos)
			}
			bound, pos := u.Name.Name, u.Name.Pos
			if u.Alias != nil {
				bound, pos = u.Alias.Name, u.Alias.Pos
			}
			if _, dup := m.imports[bound]; dup {
				c.fail(diag.DupName, pos)
			}
			m.imports[bound] = target
		}
	}
}

// ---------------------------------------------------------------- pass 3.3

func (c *checker) dupIdents(names []ast.Ident) {
	seen := map[string]bool{}
	for _, n := range names {
		if seen[n.Name] {
			c.fail(diag.DupName, n.Pos)
		}
		seen[n.Name] = true
	}
}

func genNames(gs []*ast.GenParam) []ast.Ident {
	var ns []ast.Ident
	for _, g := range gs {
		ns = append(ns, g.Name)
	}
	return ns
}

func paramNames(ps []*ast.Param) []ast.Ident {
	var ns []ast.Ident
	for _, p := range ps {
		ns = append(ns, p.Name)
	}
	return ns
}

func (c *checker) methodDups(ms []*ast.MethodDecl) {
	var names []ast.Ident
	for _, m := range ms {
		names = append(names, m.Name)
	}
	c.dupIdents(names)
	for _, m := range ms {
		c.dupIdents(paramNames(m.Params))
	}
}

func (c *checker) internalDups() {
	for _, m := range c.mods {
		for _, it := range m.ast.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				c.dupIdents(genNames(d.Generics))
				c.dupIdents(paramNames(d.Params))
			case *ast.StructDecl:
				c.dupIdents(genNames(d.Generics))
				var fs []ast.Ident
				for _, f := range d.Fields {
					fs = append(fs, f.Name)
				}
				c.dupIdents(fs)
			case *ast.EnumDecl:
				c.dupIdents(genNames(d.Generics))
			case *ast.TraitDecl:
				c.methodDups(d.Methods)
			case *ast.ImplDecl:
				c.dupIdents(genNames(d.Generics))
				c.methodDups(d.Methods)
			}
		}
	}
}

// ---------------------------------------------------------------- pass 3.4

func (c *checker) signatures() {
	for _, m := range c.mods {
		for _, it := range m.ast.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				f := d.Func
				ctx := &tctx{mod: m, tparams: map[string]*types.TypeParam{}}
				for _, p := range f.TParams {
					ctx.tparams[p.Name] = p
				}
				c.resolveBounds(d.Generics, f.TParams, ctx)
				for _, p := range d.Params {
					f.Params = append(f.Params, c.resolveType(ctx, p.Type))
				}
				f.Ret = types.Unit
				if d.Ret != nil {
					f.Ret = c.resolveType(ctx, d.Ret)
				}
			case *ast.StructDecl:
				ctx := &tctx{mod: m, tparams: map[string]*types.TypeParam{}}
				for _, p := range d.Decl.TParams {
					ctx.tparams[p.Name] = p
				}
				for _, f := range d.Fields {
					d.Decl.Fields = append(d.Decl.Fields, types.Field{Name: f.Name.Name, Type: c.resolveType(ctx, f.Type)})
				}
			case *ast.EnumDecl:
				ctx := &tctx{mod: m, tparams: map[string]*types.TypeParam{}}
				for _, p := range d.Decl.TParams {
					ctx.tparams[p.Name] = p
				}
				for i, v := range d.Variants {
					for _, t := range v.Payload {
						d.Decl.Variants[i].Payload = append(d.Decl.Variants[i].Payload, c.resolveType(ctx, t))
					}
				}
			case *ast.TraitDecl:
				tr := d.Trait
				ctx := &tctx{mod: m, tparams: map[string]*types.TypeParam{}, self: types.NewParam(tr.SelfParam)}
				for i, md := range d.Methods {
					tm := &types.TraitMethod{Name: md.Name.Name, Index: i, HasDefault: md.Body != nil}
					for _, p := range md.Params {
						tm.Params = append(tm.Params, c.resolveType(ctx, p.Type))
					}
					tm.Ret = types.Unit
					if md.Ret != nil {
						tm.Ret = c.resolveType(ctx, md.Ret)
					}
					tr.Methods = append(tr.Methods, tm)
					if md.Body != nil {
						f := &types.Func{Name: md.Name.Name, Module: m.tmod, Builtin: -1}
						f.Params = append([]*types.Type{types.NewParam(tr.SelfParam)}, tm.Params...)
						f.Ret = tm.Ret
						tm.Default = f
						md.Func = f
					}
				}
			case *ast.ImplDecl:
				c.implSignature(m, d)
			}
		}
	}
}

func (c *checker) implSignature(m *modInfo, d *ast.ImplDecl) {
	ctx := &tctx{mod: m, tparams: map[string]*types.TypeParam{}}
	tps := c.makeTParams(d.Generics, ctx)
	c.resolveBounds(d.Generics, tps, ctx)
	tr := c.resolveTrait(m, d.Trait)
	// Self in the head is not allowed; resolve it to a placeholder so that
	// pass 3.5 reports bad-impl-head.
	ctx.self = types.NewParam(&types.TypeParam{Name: "Self"})
	head := c.resolveType(ctx, d.Head)
	ctx.self = head
	impl := &types.Impl{Trait: tr, Ctor: head.Ctor(), TParams: tps, Head: head}
	d.Impl = impl
	for _, md := range d.Methods {
		f := &types.Func{Name: md.Name.Name, Module: m.tmod, Builtin: -1}
		f.Params = append(f.Params, head)
		for _, p := range md.Params {
			f.Params = append(f.Params, c.resolveType(ctx, p.Type))
		}
		f.Ret = types.Unit
		if md.Ret != nil {
			f.Ret = c.resolveType(ctx, md.Ret)
		}
		md.Func = f
	}
}

// ---------------------------------------------------------------- pass 3.5

func (c *checker) checkImpls() {
	for _, m := range c.mods {
		for _, it := range m.ast.Items {
			d, ok := it.(*ast.ImplDecl)
			if !ok {
				continue
			}
			impl := d.Impl
			if impl.Trait.Builtin != types.UserTrait {
				c.fail(diag.BuiltinTraitImpl, d.Pos)
			}
			if !c.validHead(impl) {
				c.fail(diag.BadImplHead, d.Head.TypePos())
			}
			for i, p := range impl.TParams {
				if !occursParam(impl.Head, p) {
					c.fail(diag.UnusedParam, d.Generics[i].Name.Pos)
				}
			}
			key := implKey{impl.Trait, impl.Ctor}
			if _, dup := c.impls[key]; dup {
				c.fail(diag.DupImpl, d.Pos)
			}
			c.impls[key] = impl
			c.implList = append(c.implList, impl)
			tr := impl.Trait
			defined := map[string]*ast.MethodDecl{}
			for _, md := range d.Methods {
				defined[md.Name.Name] = md
			}
			for _, tm := range tr.Methods {
				if !tm.HasDefault && defined[tm.Name] == nil {
					c.fail(diag.MissingMethod, d.Pos)
				}
			}
			impl.Methods = make([]*types.Func, len(tr.Methods))
			for _, md := range d.Methods {
				mi := tr.MethodIndex(md.Name.Name)
				if mi < 0 {
					c.fail(diag.ExtraMethod, md.Name.Pos)
				}
				tm := tr.Methods[mi]
				sub := map[*types.TypeParam]*types.Type{tr.SelfParam: impl.Head}
				ok := len(md.Func.Params)-1 == len(tm.Params)
				if ok {
					for i, pt := range tm.Params {
						if !types.Equal(types.Subst(pt, sub), md.Func.Params[i+1]) {
							ok = false
						}
					}
				}
				if ok && !types.Equal(types.Subst(tm.Ret, sub), md.Func.Ret) {
					ok = false
				}
				if !ok {
					c.fail(diag.SigMismatch, md.Name.Pos)
				}
				impl.Methods[mi] = md.Func
			}
		}
	}
}

func occursParam(t *types.Type, p *types.TypeParam) bool {
	t = types.Resolve(t)
	if t.Kind == types.KParam {
		return t.Param == p
	}
	for _, a := range t.Args {
		if occursParam(a, p) {
			return true
		}
	}
	if t.Kind == types.KFunc {
		return occursParam(t.Ret, p)
	}
	return false
}

// validHead implements the impl-head rules of section 8.2.
func (c *checker) validHead(impl *types.Impl) bool {
	own := map[*types.TypeParam]bool{}
	for _, p := range impl.TParams {
		own[p] = true
	}
	isOwn := func(t *types.Type) *types.TypeParam {
		if t.Kind == types.KParam && own[t.Param] {
			return t.Param
		}
		return nil
	}
	h := impl.Head
	switch h.Kind {
	case types.KInt, types.KFloat, types.KBool, types.KChar, types.KStr, types.KUnit:
		return true
	case types.KList:
		return isOwn(h.Args[0]) != nil
	case types.KMap:
		p, q := isOwn(h.Args[0]), isOwn(h.Args[1])
		return p != nil && q != nil && p != q
	case types.KNamed:
		seen := map[*types.TypeParam]bool{}
		for _, a := range h.Args {
			p := isOwn(a)
			if p == nil || seen[p] {
				return false
			}
			seen[p] = true
		}
		return true
	}
	return false
}

// ---------------------------------------------------------------- pass 3.6

func (c *checker) entryPoint() *types.Func {
	m := c.byName["main"]
	pos := diag.Pos{Line: 1, Col: 1}
	if m == nil {
		c.fail(diag.NoMain, pos)
	}
	e, ok := m.valuesNS["main"]
	if !ok || e.fn == nil {
		c.fail(diag.NoMain, pos)
	}
	f := e.fn
	if len(f.TParams) != 0 || len(f.Params) != 0 || types.Resolve(f.Ret).Kind != types.KUnit {
		c.fail(diag.NoMain, pos)
	}
	return f
}

// ---------------------------------------------------------------- pass 4

func (c *checker) bodies() {
	for _, m := range c.mods {
		for _, it := range m.ast.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				c.checkFunc(m, d.Func, d.Pos, d.Params, d.Body, nil, d.Func.TParams, false)
			case *ast.TraitDecl:
				for _, md := range d.Methods {
					if md.Body != nil {
						c.checkFunc(m, md.Func, md.Pos, md.Params, md.Body, types.NewParam(d.Trait.SelfParam), nil, true)
					}
				}
			case *ast.ImplDecl:
				for _, md := range d.Methods {
					c.checkFunc(m, md.Func, md.Pos, md.Params, md.Body, d.Impl.Head, d.Impl.TParams, true)
				}
			}
		}
	}
}

// visibleTraitsByName returns the traits visible in module m named name, in
// the lookup order of section 5.4 (first element wins).
func (c *checker) visibleTraitByName(m *modInfo, name string) *types.Trait {
	if t, ok := m.traitsNS[name]; ok {
		return t
	}
	bound := make([]string, 0, len(m.imports))
	for k := range m.imports {
		bound = append(bound, k)
	}
	sort.Strings(bound)
	for _, k := range bound {
		im := m.imports[k]
		if im == m {
			continue
		}
		if t, ok := im.traitsNS[name]; ok && t.Pub {
			return t
		}
	}
	switch name {
	case "Eq":
		return c.eqTrait
	case "Ord":
		return c.ordTrait
	case "Key":
		return c.keyTrait
	}
	return nil
}

// visibleTraits returns every distinct user trait visible in m.
func (c *checker) visibleTraits(m *modInfo) []*types.Trait {
	seen := map[*types.Trait]bool{}
	var out []*types.Trait
	add := func(t *types.Trait) {
		if !seen[t] {
			seen[t] = true
			out = append(out, t)
		}
	}
	for _, t := range m.traits {
		add(t)
	}
	for _, im := range m.imports {
		if im == m {
			continue
		}
		for _, t := range im.traits {
			if t.Pub {
				add(t)
			}
		}
	}
	return out
}
