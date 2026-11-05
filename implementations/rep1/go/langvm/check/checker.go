package check

import (
	"sort"

	"langvm/ast"
	"langvm/builtins"
	"langvm/diag"
	"langvm/lexer"
	"langvm/parser"
)

type bail struct{ err *diag.Error }

type implKey struct{ trait, ctor int }

// Checker holds the state of one checking run.
type Checker struct {
	prog    *Program
	prelude *Module
	byName  map[string]*Module
	eq, ord *Trait
	key     *Trait
	impls   map[implKey]*Impl
	nVars   int
}

func (c *Checker) fail(k diag.Kind, p ast.Pos) {
	panic(bail{diag.New(k, p)})
}

var primTypes = map[string]*Type{
	"Int": TInt, "Float": TFloat, "Bool": TBool, "Char": TChar, "Str": TStr, "Unit": TUnit,
}

func isReserved(name string) bool {
	if _, ok := primTypes[name]; ok {
		return true
	}
	return name == "Self"
}

// Check runs passes 3 and 4 over the parsed modules (in stream order).
func Check(mods []*ast.Module) (prog *Program, err *diag.Error) {
	c := &Checker{byName: map[string]*Module{}, impls: map[implKey]*Impl{}}
	defer func() {
		if r := recover(); r != nil {
			if b, ok := r.(bail); ok {
				prog, err = nil, b.err
				return
			}
			panic(r)
		}
	}()
	c.prog = &Program{}
	c.buildPrelude()
	for i, am := range mods {
		m := &Module{
			Name: am.Name, Index: i, AST: am,
			Types: map[string]*TypeDecl{}, Traits: map[string]*Trait{},
			Values: map[string]any{}, Imports: map[string]*Module{},
		}
		c.prog.Modules = append(c.prog.Modules, m)
		c.byName[am.Name] = m
	}
	c.declare()
	c.imports()
	c.internalDups()
	c.signatures()
	c.implChecks()
	c.entryPoint()
	c.prog.NumCtors = CtorDeclBase + len(c.prog.Types)
	c.bodies()
	return c.prog, nil
}

// ------------------------------------------------------------------ prelude

func (c *Checker) newTypeDecl(name string, m *Module, pub, isEnum bool) *TypeDecl {
	d := &TypeDecl{Name: name, Mod: m, Pub: pub, IsEnum: isEnum, ID: len(c.prog.Types)}
	c.prog.Types = append(c.prog.Types, d)
	return d
}

func (c *Checker) buildPrelude() {
	p := &Module{
		Name: "<prelude>", Index: -1,
		Types: map[string]*TypeDecl{}, Traits: map[string]*Trait{},
		Values: map[string]any{}, Imports: map[string]*Module{},
	}
	c.prelude = p
	c.prog.Prelude = p
	mk := func(name string, tparams []string, vars map[string][]int) *TypeDecl {
		d := c.newTypeDecl(name, p, true, true)
		for _, tp := range tparams {
			d.Params = append(d.Params, newParam(tp))
		}
		p.Types[name] = d
		return d
	}
	opt := mk("Option", []string{"T"}, nil)
	opt.addVariant("Some", opt.Params[0].T)
	opt.addVariant("None")
	res := mk("Result", []string{"T", "E"}, nil)
	res.addVariant("Ok", res.Params[0].T)
	res.addVariant("Err", res.Params[1].T)
	c.prog.Option, c.prog.Result = opt, res
	for _, d := range []*TypeDecl{opt, res} {
		for _, v := range d.Variants {
			p.Values[v.Name] = v
		}
	}
	for i, n := range []string{"Eq", "Ord", "Key"} {
		t := &Trait{Name: n, Mod: p, Pub: true, Builtin: i + 1, ID: -1, ByName: map[string]*Method{}}
		p.Traits[n] = t
	}
	c.eq, c.ord, c.key = p.Traits["Eq"], p.Traits["Ord"], p.Traits["Key"]

	// Built-in functions: parse their signatures as Vellum fn headers.
	for id, spec := range builtins.Specs {
		toks, lerr := lexer.Lex([]rune(spec.Sig + " {}"))
		if lerr != nil {
			panic("bad builtin signature " + spec.Name)
		}
		am, perr := parser.Parse("prelude", toks)
		if perr != nil {
			panic("bad builtin signature " + spec.Name + ": " + perr.Error())
		}
		fd := am.Items[0].(*ast.FnDecl)
		f := &Func{Name: spec.Name, Mod: p, Pub: true, Decl: fd, Builtin: id}
		c.fillFuncSig(f, fd, nil, p)
		p.Values[spec.Name] = f
	}
}

func (d *TypeDecl) addVariant(name string, payload ...*Type) {
	d.Variants = append(d.Variants, &Variant{Name: name, Enum: d, Index: len(d.Variants), Payload: payload})
}

// ---------------------------------------------------------- scopes and types

type tscope struct {
	mod    *Module
	params map[string]*TypeParam
	self   *Type
}

func (c *Checker) makeParams(gs []*ast.GenParam) ([]*TypeParam, map[string]*TypeParam) {
	m := map[string]*TypeParam{}
	var out []*TypeParam
	for _, g := range gs {
		p := newParam(g.Name.Name)
		out = append(out, p)
		m[g.Name.Name] = p
	}
	return out, m
}

func (c *Checker) resolveBounds(gs []*ast.GenParam, ps []*TypeParam, mod *Module) {
	for i, g := range gs {
		for _, b := range g.Bounds {
			ps[i].Bounds = append(ps[i].Bounds, c.resolveTraitRef(b, mod))
		}
	}
}

func (c *Checker) resolveTraitRef(tr *ast.TraitRef, mod *Module) *Trait {
	if tr.Mod == nil {
		if t, ok := mod.Traits[tr.Name.Name]; ok {
			return t
		}
		if t, ok := c.prelude.Traits[tr.Name.Name]; ok {
			return t
		}
		c.fail(diag.UnknownTrait, tr.Name.Pos)
	}
	m := mod.Imports[tr.Mod.Name]
	if m == nil {
		c.fail(diag.UnknownModule, tr.Mod.Pos)
	}
	t, ok := m.Traits[tr.Name.Name]
	if !ok {
		c.fail(diag.UnknownTrait, tr.Name.Pos)
	}
	if !t.Pub && m != mod {
		c.fail(diag.NotPublic, tr.Name.Pos)
	}
	return t
}

func (c *Checker) isKeyType(t *Type) bool {
	t = prune(t)
	switch t.Kind {
	case KInt, KBool, KChar, KStr:
		return true
	case KParam:
		return t.Param.hasBound(c.key)
	}
	return false
}

// lookupTypeDecl resolves a (possibly qualified) type name to a declaration.
func (c *Checker) lookupTypeDecl(mod *Module, qual *ast.Ident, name ast.Ident) *TypeDecl {
	if qual == nil {
		if d, ok := mod.Types[name.Name]; ok {
			return d
		}
		if d, ok := c.prelude.Types[name.Name]; ok {
			return d
		}
		c.fail(diag.UnknownType, name.Pos)
	}
	m := mod.Imports[qual.Name]
	if m == nil {
		c.fail(diag.UnknownModule, qual.Pos)
	}
	d, ok := m.Types[name.Name]
	if !ok {
		c.fail(diag.UnknownType, name.Pos)
	}
	if !d.Pub && m != mod {
		c.fail(diag.NotPublic, name.Pos)
	}
	return d
}

func (c *Checker) resolveType(te *ast.TypeExpr, sc *tscope) *Type {
	switch te.Kind {
	case ast.TList:
		return listOf(c.resolveType(te.Args[0], sc))
	case ast.TMap:
		k := c.resolveType(te.Args[0], sc)
		v := c.resolveType(te.Args[1], sc)
		if !c.isKeyType(k) {
			c.fail(diag.BadKeyType, te.Pos)
		}
		return mapOf(k, v)
	case ast.TTuple:
		if len(te.Args) > 8 {
			c.fail(diag.BadArity, te.Pos)
		}
		elems := make([]*Type, len(te.Args))
		for i, a := range te.Args {
			elems[i] = c.resolveType(a, sc)
		}
		return &Type{Kind: KTuple, Elems: elems}
	case ast.TFn:
		if len(te.Args) > 16 {
			c.fail(diag.BadArity, te.Pos)
		}
		elems := make([]*Type, len(te.Args))
		for i, a := range te.Args {
			elems[i] = c.resolveType(a, sc)
		}
		ret := TUnit
		if te.Ret != nil {
			ret = c.resolveType(te.Ret, sc)
		}
		return &Type{Kind: KFn, Elems: elems, Ret: ret}
	}
	// path
	noArgs := func() {
		if len(te.Args) > 0 {
			c.fail(diag.ArityType, te.Pos)
		}
	}
	var decl *TypeDecl
	if te.Mod == nil {
		name := te.Name.Name
		if p, ok := sc.params[name]; ok {
			noArgs()
			return p.T
		}
		if name == "Self" {
			if sc.self == nil {
				c.fail(diag.SelfOutside, te.Pos)
			}
			noArgs()
			return sc.self
		}
		if t, ok := primTypes[name]; ok {
			noArgs()
			return t
		}
	}
	decl = c.lookupTypeDecl(sc.mod, te.Mod, te.Name)
	if len(te.Args) != len(decl.Params) {
		c.fail(diag.ArityType, te.Pos)
	}
	args := make([]*Type, len(te.Args))
	for i, a := range te.Args {
		args[i] = c.resolveType(a, sc)
	}
	return &Type{Kind: KNamed, Decl: decl, Elems: args}
}

// ---------------------------------------------------------- pass 3.1: declare

func (c *Checker) declare() {
	for _, m := range c.prog.Modules {
		for _, it := range m.AST.Items {
			switch d := it.(type) {
			case *ast.StructDecl:
				c.checkReserved(d.Name)
				if _, dup := m.Types[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				td := c.newTypeDecl(d.Name.Name, m, d.Pub, false)
				td.Struct = d
				td.Params, _ = c.makeParams(d.Generics)
				m.Types[d.Name.Name] = td
				d.Info = td
			case *ast.EnumDecl:
				c.checkReserved(d.Name)
				if _, dup := m.Types[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				td := c.newTypeDecl(d.Name.Name, m, d.Pub, true)
				td.Enum = d
				td.Params, _ = c.makeParams(d.Generics)
				m.Types[d.Name.Name] = td
				d.Info = td
				for i, v := range d.Variants {
					if _, dup := m.Values[v.Name.Name]; dup {
						c.fail(diag.DupName, v.Name.Pos)
					}
					vr := &Variant{Name: v.Name.Name, Enum: td, Index: i, Pos: v.Name.Pos}
					td.Variants = append(td.Variants, vr)
					m.Values[v.Name.Name] = vr
				}
			case *ast.TraitDecl:
				c.checkReserved(d.Name)
				if _, dup := m.Traits[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				t := &Trait{Name: d.Name.Name, Mod: m, Pub: d.Pub, ID: c.prog.nextTrait,
					ByName: map[string]*Method{}, Decl: d}
				c.prog.nextTrait++
				t.Self = newParam("Self")
				t.Self.Bounds = []*Trait{t}
				c.prog.Traits = append(c.prog.Traits, t)
				m.Traits[d.Name.Name] = t
				m.TraitList = append(m.TraitList, t)
				d.Info = t
			case *ast.FnDecl:
				if _, dup := m.Values[d.Name.Name]; dup {
					c.fail(diag.DupName, d.Name.Pos)
				}
				f := &Func{Name: d.Name.Name, Mod: m, Pub: d.Pub, Decl: d, Builtin: -1}
				d.Info = f
				m.Values[d.Name.Name] = f
			}
		}
	}
}

func (c *Checker) checkReserved(name ast.Ident) {
	if isReserved(name.Name) {
		c.fail(diag.ReservedName, name.Pos)
	}
}

// ------------------------------------------------------- pass 3.2: imports

func (c *Checker) imports() {
	for _, m := range c.prog.Modules {
		for _, it := range m.AST.Items {
			u, ok := it.(*ast.UseDecl)
			if !ok {
				continue
			}
			target := c.byName[u.Module.Name]
			if target == nil {
				c.fail(diag.UnknownModule, u.Module.Pos)
			}
			bound := u.Module
			if u.Alias != nil {
				bound = *u.Alias
			}
			if _, dup := m.Imports[bound.Name]; dup {
				c.fail(diag.DupName, bound.Pos)
			}
			m.Imports[bound.Name] = target
		}
	}
}

// ------------------------------------------------ pass 3.3: internal dups

func dupGenerics(c *Checker, gs []*ast.GenParam) {
	seen := map[string]bool{}
	for _, g := range gs {
		if seen[g.Name.Name] {
			c.fail(diag.DupName, g.Name.Pos)
		}
		seen[g.Name.Name] = true
	}
}

func dupParams(c *Checker, ps []*ast.Param) {
	seen := map[string]bool{}
	for _, p := range ps {
		if seen[p.Name.Name] {
			c.fail(diag.DupName, p.Name.Pos)
		}
		seen[p.Name.Name] = true
	}
}

func dupMethods(c *Checker, ms []*ast.FnDecl) {
	seen := map[string]bool{}
	for _, m := range ms {
		if seen[m.Name.Name] {
			c.fail(diag.DupName, m.Name.Pos)
		}
		seen[m.Name.Name] = true
	}
	for _, m := range ms {
		dupParams(c, m.Params)
	}
}

func (c *Checker) internalDups() {
	for _, m := range c.prog.Modules {
		for _, it := range m.AST.Items {
			switch d := it.(type) {
			case *ast.StructDecl:
				dupGenerics(c, d.Generics)
				seen := map[string]bool{}
				for _, f := range d.Fields {
					if seen[f.Name.Name] {
						c.fail(diag.DupName, f.Name.Pos)
					}
					seen[f.Name.Name] = true
				}
			case *ast.EnumDecl:
				dupGenerics(c, d.Generics)
			case *ast.FnDecl:
				dupGenerics(c, d.Generics)
				dupParams(c, d.Params)
			case *ast.TraitDecl:
				dupMethods(c, d.Methods)
			case *ast.ImplDecl:
				dupGenerics(c, d.Generics)
				dupMethods(c, d.Methods)
			}
		}
	}
}

// --------------------------------------------------- pass 3.4: signatures

// fillFuncSig resolves a function's header. outer supplies the enclosing
// scope's type parameters and Self (for methods); mod is the current module.
func (c *Checker) fillFuncSig(f *Func, d *ast.FnDecl, outer *tscope, mod *Module) {
	sc := &tscope{mod: mod, params: map[string]*TypeParam{}}
	if outer != nil {
		for k, v := range outer.params {
			sc.params[k] = v
		}
		sc.self = outer.self
	}
	if len(d.Generics) > 0 {
		f.TParams, _ = c.makeParams(d.Generics)
		for _, p := range f.TParams {
			sc.params[p.Name] = p
		}
		c.resolveBounds(d.Generics, f.TParams, mod)
	}
	f.Params = make([]*Type, len(d.Params))
	for i, p := range d.Params {
		f.Params[i] = c.resolveType(p.Type, sc)
	}
	f.Ret = TUnit
	if d.Ret != nil {
		f.Ret = c.resolveType(d.Ret, sc)
	}
}

func (c *Checker) signatures() {
	for _, m := range c.prog.Modules {
		for _, it := range m.AST.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				c.fillFuncSig(d.Info.(*Func), d, nil, m)
			case *ast.StructDecl:
				td := d.Info.(*TypeDecl)
				sc := c.declScope(m, td)
				for _, f := range d.Fields {
					td.Fields = append(td.Fields, Field{Name: f.Name.Name, Type: c.resolveType(f.Type, sc)})
				}
			case *ast.EnumDecl:
				td := d.Info.(*TypeDecl)
				sc := c.declScope(m, td)
				for i, v := range d.Variants {
					for _, pt := range v.Payload {
						td.Variants[i].Payload = append(td.Variants[i].Payload, c.resolveType(pt, sc))
					}
				}
			case *ast.TraitDecl:
				c.traitSig(m, d)
			case *ast.ImplDecl:
				c.implSig(m, d)
			}
		}
	}
}

func (c *Checker) declScope(m *Module, td *TypeDecl) *tscope {
	sc := &tscope{mod: m, params: map[string]*TypeParam{}}
	for _, p := range td.Params {
		sc.params[p.Name] = p
	}
	return sc
}

func (c *Checker) traitSig(m *Module, d *ast.TraitDecl) {
	t := d.Info.(*Trait)
	sc := &tscope{mod: m, params: map[string]*TypeParam{}, self: t.Self.T}
	for i, md := range d.Methods {
		f := &Func{Name: md.Name.Name, Mod: m, Pub: d.Pub, Decl: md, Builtin: -1, Trait: t}
		c.fillFuncSig(f, md, sc, m)
		meth := &Method{Name: md.Name.Name, Trait: t, Index: i, Params: f.Params, Ret: f.Ret, Decl: md}
		f.Method = meth
		md.Info = f
		if md.Body != nil {
			meth.Default = f
		}
		t.Methods = append(t.Methods, meth)
		t.ByName[meth.Name] = meth
	}
}

func (c *Checker) implSig(m *Module, d *ast.ImplDecl) {
	impl := &Impl{Mod: m, Decl: d}
	d.Info = impl
	var params map[string]*TypeParam
	impl.TParams, params = c.makeParams(d.Generics)
	c.resolveBounds(d.Generics, impl.TParams, m)
	impl.Trait = c.resolveTraitRef(d.Trait, m)
	placeholder := newParam("Self")
	sc := &tscope{mod: m, params: params, self: placeholder.T}
	impl.Head = c.resolveType(d.Head, sc)
	impl.Ctor = ctorOf(impl.Head)
	sc.self = impl.Head
	for _, md := range d.Methods {
		f := &Func{Name: md.Name.Name, Mod: m, Decl: md, Builtin: -1, Trait: impl.Trait, Impl: impl}
		c.fillFuncSig(f, md, sc, m)
		md.Info = f
		impl.Methods = append(impl.Methods, f)
	}
}

// ------------------------------------------------------- pass 3.5: impls

func (c *Checker) validHead(impl *Impl) bool {
	own := func(t *Type) *TypeParam {
		t = prune(t)
		if t.Kind != KParam {
			return nil
		}
		for _, p := range impl.TParams {
			if p == t.Param {
				return p
			}
		}
		return nil
	}
	h := impl.Head
	switch h.Kind {
	case KInt, KFloat, KBool, KChar, KStr, KUnit:
		return true
	case KList:
		return own(h.Elems[0]) != nil
	case KMap:
		a, b := own(h.Elems[0]), own(h.Elems[1])
		return a != nil && b != nil && a != b
	case KNamed:
		seen := map[*TypeParam]bool{}
		for _, e := range h.Elems {
			p := own(e)
			if p == nil || seen[p] {
				return false
			}
			seen[p] = true
		}
		return true
	}
	return false
}

func occursParam(t *Type, p *TypeParam) bool {
	t = prune(t)
	if t.Kind == KParam {
		return t.Param == p
	}
	for _, e := range t.Elems {
		if occursParam(e, p) {
			return true
		}
	}
	if t.Ret != nil {
		return occursParam(t.Ret, p)
	}
	return false
}

func (c *Checker) implChecks() {
	for _, m := range c.prog.Modules {
		for _, it := range m.AST.Items {
			d, ok := it.(*ast.ImplDecl)
			if !ok {
				continue
			}
			impl := d.Info.(*Impl)
			tr := impl.Trait
			if tr.Builtin != 0 {
				c.fail(diag.BuiltinTraitImpl, d.Pos)
			}
			if !c.validHead(impl) {
				c.fail(diag.BadImplHead, d.Head.Pos)
			}
			for i, p := range impl.TParams {
				if !occursParam(impl.Head, p) {
					c.fail(diag.UnusedParam, d.Generics[i].Name.Pos)
				}
			}
			key := implKey{tr.ID, impl.Ctor}
			if _, dup := c.impls[key]; dup {
				c.fail(diag.DupImpl, d.Pos)
			}
			c.impls[key] = impl
			c.prog.Impls = append(c.prog.Impls, impl)
			defined := map[string]*Func{}
			for _, f := range impl.Methods {
				defined[f.Name] = f
			}
			for _, mt := range tr.Methods {
				if mt.Default == nil && defined[mt.Name] == nil {
					c.fail(diag.MissingMethod, d.Pos)
				}
			}
			byIdx := make([]*Func, len(tr.Methods))
			sm := map[*TypeParam]*Type{tr.Self: impl.Head}
			for _, f := range impl.Methods {
				mt, ok := tr.ByName[f.Name]
				if !ok {
					c.fail(diag.ExtraMethod, f.Decl.Name.Pos)
				}
				okSig := len(f.Params) == len(mt.Params) && equalTypes(f.Ret, subst(mt.Ret, sm))
				if okSig {
					for i := range f.Params {
						if !equalTypes(f.Params[i], subst(mt.Params[i], sm)) {
							okSig = false
							break
						}
					}
				}
				if !okSig {
					c.fail(diag.SigMismatch, f.Decl.Name.Pos)
				}
				f.Method = mt
				byIdx[mt.Index] = f
			}
			impl.Methods = byIdx
		}
	}
}

// ------------------------------------------------------ pass 3.6: main

func (c *Checker) entryPoint() {
	m := c.byName["main"]
	if m == nil {
		c.fail(diag.NoMain, ast.Pos{Line: 1, Col: 1})
	}
	f, ok := m.Values["main"].(*Func)
	if !ok || len(f.TParams) != 0 || len(f.Params) != 0 || prune(f.Ret) != TUnit {
		c.fail(diag.NoMain, ast.Pos{Line: 1, Col: 1})
	}
	c.prog.Main = f
}

// ------------------------------------------------------------- visibility

// visibleTraits returns every trait visible in mod, in lookup order for
// qualified `Tr::m` paths (SPEC 5.4): own traits, then pub traits of the
// imports in increasing bound-name order, then the built-ins.
func (c *Checker) visibleTraits(mod *Module) []*Trait {
	var out []*Trait
	out = append(out, mod.TraitList...)
	names := make([]string, 0, len(mod.Imports))
	for n := range mod.Imports {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		im := mod.Imports[n]
		if im == mod {
			continue
		}
		for _, t := range im.TraitList {
			if t.Pub {
				out = append(out, t)
			}
		}
	}
	return out
}
