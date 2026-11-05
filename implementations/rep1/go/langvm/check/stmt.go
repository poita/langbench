package check

import (
	"langvm/ast"
	"langvm/diag"
)

func (b *body) stmt(s ast.Stmt) {
	switch n := s.(type) {
	case *ast.LetStmt:
		var t *Type
		if n.Type != nil {
			t = b.c.resolveType(n.Type, b.sc)
			b.check(n.Init, t)
		} else {
			t = b.infer(n.Init)
		}
		b.pattern(n.Pat, t)
		if !irrefutable(n.Pat) {
			b.fail(diag.RefutablePattern, n.Pat.PatPos())
		}
	case *ast.VarStmt:
		var t *Type
		if n.Type != nil {
			t = b.c.resolveType(n.Type, b.sc)
			b.check(n.Init, t)
		} else {
			t = b.infer(n.Init)
		}
		n.Local = b.declare(n.Name.Name, true, t)
	case *ast.AssignStmt:
		b.assign(n)
	case *ast.ExprStmt:
		b.infer(n.X)
	case *ast.ReturnStmt:
		b.returnStmt(n)
	case *ast.WhileStmt:
		b.check(n.Cond, TBool)
		b.loopBody(n.Body)
	case *ast.ForStmt:
		b.forStmt(n)
	case *ast.BreakStmt:
		if b.fn.Loops == 0 {
			b.fail(diag.BreakOutside, n.P)
		}
	case *ast.ContinueStmt:
		if b.fn.Loops == 0 {
			b.fail(diag.BreakOutside, n.P)
		}
	}
}

// loopBody checks a statement block (SPEC 11.7) inside a loop.
func (b *body) loopBody(blk *ast.Block) {
	b.fn.Loops++
	b.push()
	for _, s := range blk.Stmts {
		b.stmt(s)
	}
	if blk.Tail != nil {
		b.infer(blk.Tail)
	}
	b.pop()
	b.fn.Loops--
}

func (b *body) forStmt(n *ast.ForStmt) {
	var elem *Type
	if n.Hi != nil {
		b.check(n.Seq, TInt)
		b.check(n.Hi, TInt)
		elem = TInt
		n.Sem = SemInt
	} else {
		s := prune(b.infer(n.Seq))
		switch s.Kind {
		case KList:
			elem = s.Elems[0]
			n.Sem = SemList
		case KStr:
			elem = TChar
			n.Sem = SemStr
		default:
			b.fail(diag.NotIterable, n.Seq.Position())
		}
	}
	b.push()
	b.pattern(n.Pat, elem)
	if !irrefutable(n.Pat) {
		b.fail(diag.RefutablePattern, n.Pat.PatPos())
	}
	b.loopBody(n.Body)
	b.pop()
}

func (b *body) returnStmt(n *ast.ReturnStmt) {
	ret := b.fn.Ret
	if ret == nil {
		b.fail(diag.CannotInfer, n.P)
	}
	if n.X == nil {
		if !unify(ret, TUnit) {
			b.fail(diag.TypeMismatch, n.P)
		}
		return
	}
	if prune(ret).Kind == KUnit {
		t := prune(b.infer(n.X))
		if t.Kind != KUnit {
			b.fail(diag.TypeMismatch, n.P)
		}
		return
	}
	b.check(n.X, ret)
}

// Assignment target kinds recorded in AssignStmt.Sem.
const (
	AssignLocal = iota
	AssignList
	AssignMap
)

func (b *body) assign(n *ast.AssignStmt) {
	switch t := n.Target.(type) {
	case *ast.PathExpr:
		if t.Mod != nil {
			b.fail(diag.BadTarget, t.P)
		}
		l := b.lookup(t.Name.Name)
		if l == nil {
			b.fail(diag.UnknownName, t.Name.Pos)
		}
		if !l.Mutable {
			b.fail(diag.AssignImmutable, t.Name.Pos)
		}
		if l.Owner != b.fn {
			b.fail(diag.AssignCaptured, t.Name.Pos)
		}
		t.Res = l
		n.Sem = AssignLocal
		b.check(n.Value, l.Type)
	case *ast.IndexExpr:
		a := prune(b.infer(t.X))
		switch a.Kind {
		case KList:
			b.check(t.Index, TInt)
			b.check(n.Value, a.Elems[0])
			n.Sem = AssignList
		case KMap:
			b.check(t.Index, a.Elems[0])
			b.check(n.Value, a.Elems[1])
			n.Sem = AssignMap
		default:
			b.fail(diag.BadTarget, t.X.Position())
		}
	default:
		b.fail(diag.BadTarget, n.Target.Position())
	}
}
