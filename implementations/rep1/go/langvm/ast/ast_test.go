package ast

import "testing"

func TestDiverges(t *testing.T) {
	ret := &ReturnStmt{}
	if !StmtDiverges(ret) || !StmtDiverges(&BreakStmt{}) || !StmtDiverges(&ContinueStmt{}) {
		t.Fatal("return, break and continue diverge")
	}
	if StmtDiverges(&WhileStmt{}) || StmtDiverges(&ForStmt{}) {
		t.Fatal("loops never diverge")
	}
	b := &Block{Div: true}
	if !Diverges(b) || !StmtDiverges(&ExprStmt{X: b}) || !StmtDiverges(&LetStmt{Init: b}) {
		t.Fatal("a diverging block makes its statement diverge")
	}
	if Diverges(&Call{Callee: &PathExpr{}}) {
		t.Fatal("calls never diverge")
	}
}

func TestPositions(t *testing.T) {
	l := &IntLit{P: Pos{Line: 2, Col: 5}}
	bin := &Binary{L: l, R: &IntLit{P: Pos{Line: 2, Col: 9}}}
	if bin.Position() != l.P {
		t.Fatal("a binary expression is positioned at its first token")
	}
	call := &MethodCall{Recv: l, Name: Ident{Name: "m", Pos: Pos{Line: 2, Col: 7}}}
	if call.Position() != l.P {
		t.Fatal("a method call is positioned at its receiver")
	}
}
