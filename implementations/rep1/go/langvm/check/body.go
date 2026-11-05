package check

import (
	"langvm/ast"
	"langvm/diag"
)

// body checks one function body (SPEC sections 9 to 12).
type body struct {
	c       *Checker
	mod     *Module
	sc      *tscope
	fn      *FnInfo
	binds   []*Local
	marks   []int
	vscopes [][]*Type
	selfTy  *Type
}

func (b *body) fail(k diag.Kind, p ast.Pos) { b.c.fail(k, p) }

func (b *body) push() { b.marks = append(b.marks, len(b.binds)) }
func (b *body) pop() {
	n := b.marks[len(b.marks)-1]
	b.marks = b.marks[:len(b.marks)-1]
	b.binds = b.binds[:n]
}

func (b *body) declare(name string, mutable bool, t *Type) *Local {
	l := &Local{Name: name, Mutable: mutable, Type: t, Owner: b.fn}
	b.binds = append(b.binds, l)
	return l
}

func (b *body) lookup(name string) *Local {
	for i := len(b.binds) - 1; i >= 0; i-- {
		if b.binds[i].Name == name {
			return b.binds[i]
		}
	}
	return nil
}

// useLocal records the captures needed for reading l from the current function.
func (b *body) useLocal(l *Local) {
	if l.Owner == b.fn {
		return
	}
	for f := b.fn; f != nil && f != l.Owner; f = f.Parent {
		f.capture(l)
	}
}

// ---------------------------------------------------------- inference vars

func (b *body) newVar() *Type {
	v := &Type{Kind: KVar}
	if n := len(b.vscopes); n > 0 {
		b.vscopes[n-1] = append(b.vscopes[n-1], v)
	}
	return v
}

func (b *body) pushVars() { b.vscopes = append(b.vscopes, nil) }

// popVars pops the innermost variable scope; every variable created in it
// must be solved, else cannot-infer at pos.
func (b *body) popVars(pos ast.Pos) {
	n := len(b.vscopes) - 1
	vs := b.vscopes[n]
	b.vscopes = b.vscopes[:n]
	for _, v := range vs {
		if prune(v).Kind == KVar {
			b.fail(diag.CannotInfer, pos)
		}
	}
}

// -------------------------------------------------------------- entry points

func (c *Checker) bodies() {
	for _, m := range c.prog.Modules {
		for _, it := range m.AST.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				f := d.Info.(*Func)
				sc := &tscope{mod: m, params: map[string]*TypeParam{}}
				for _, p := range f.TParams {
					sc.params[p.Name] = p
				}
				c.checkFn(m, f, sc, nil)
			case *ast.TraitDecl:
				t := d.Info.(*Trait)
				for _, md := range d.Methods {
					if md.Body == nil {
						continue
					}
					sc := &tscope{mod: m, params: map[string]*TypeParam{}, self: t.Self.T}
					c.checkFn(m, md.Info.(*Func), sc, t.Self.T)
				}
			case *ast.ImplDecl:
				impl := d.Info.(*Impl)
				for _, md := range d.Methods {
					sc := &tscope{mod: m, params: map[string]*TypeParam{}, self: impl.Head}
					for _, p := range impl.TParams {
						sc.params[p.Name] = p
					}
					c.checkFn(m, md.Info.(*Func), sc, impl.Head)
				}
			}
		}
	}
}

func (c *Checker) checkFn(m *Module, f *Func, sc *tscope, self *Type) {
	d := f.Decl
	info := &FnInfo{Func: f, Ret: f.Ret}
	f.Info = info
	b := &body{c: c, mod: m, sc: sc, fn: info, selfTy: self}
	b.push()
	if d.IsMethod {
		info.Params = append(info.Params, b.declare("self", false, self))
	}
	for i, p := range d.Params {
		info.Params = append(info.Params, b.declare(p.Name.Name, false, f.Params[i]))
	}
	b.funcBody(d.Body, f.Ret, d.Pos)
	b.pop()
	c.prog.Funcs = append(c.prog.Funcs, f)
}

// funcBody checks a function, method or lambda body (SPEC 11.6).
func (b *body) funcBody(blk *ast.Block, ret *Type, kw ast.Pos) {
	b.push()
	for _, s := range blk.Stmts {
		b.stmt(s)
	}
	if blk.Tail != nil {
		b.check(blk.Tail, ret)
	} else if prune(ret).Kind != KUnit && !blk.Div {
		b.fail(diag.MissingReturn, kw)
	}
	b.pop()
}
