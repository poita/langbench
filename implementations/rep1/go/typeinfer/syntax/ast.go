package syntax

// NodeKind is the kind of an expression node.
type NodeKind uint8

// Expression node kinds. The comment on each kind says which Node fields it
// uses.
const (
	KInt    NodeKind = iota // integer literal
	KBool                   // A is 1 for true, 0 for false
	KUnit                   // ()
	KVar                    // Name
	KFun                    // Name is the parameter, A the body
	KApp                    // A applied to B
	KLet                    // let Name = A in B
	KLetRec                 // let rec Name = A in B (A is the KFun right-hand side)
	KIf                     // if A then B else C
	KTuple                  // elements Kids[A : A+B]
	KList                   // elements Kids[A : A+B]
	KCons                   // A :: B
	KBinop                  // A Op B
)

// Op is a binary operator of a KBinop node.
type Op uint8

// Binary operators.
const (
	OpAdd Op = iota
	OpSub
	OpMul
	OpDiv
	OpEq
	OpLt
	OpGt
	OpLe
	OpGe
	OpAnd
	OpOr
)

// IsArith reports whether o is + - * /.
func (o Op) IsArith() bool { return o <= OpDiv }

// IsCompare reports whether o is = < > <= >=.
func (o Op) IsCompare() bool { return o >= OpEq && o <= OpGe }

// IsLogic reports whether o is && or ||.
func (o Op) IsLogic() bool { return o >= OpAnd }

// Node is one expression node. Children are indices into Program.Nodes.
type Node struct {
	Kind    NodeKind
	Op      Op
	Name    int32 // interned identifier (KVar, KFun, KLet, KLetRec)
	A, B, C int32 // child indices; see the NodeKind constants
}

// DeclKind distinguishes the three forms of declaration.
type DeclKind uint8

// Declaration kinds.
const (
	DeclLet    DeclKind = iota // let name ... = expr ;;
	DeclLetRec                 // let rec name ... = expr ;;
	DeclExpr                   // expr ;;
)

// Decl is a top-level declaration. Expr is the index of its right-hand side
// (already desugared to nested KFun nodes if the binding had parameters).
type Decl struct {
	Kind DeclKind
	Name int32 // interned name; unused for DeclExpr
	Expr int32
}

// Program is a parsed program. All indices refer into Nodes and Kids.
type Program struct {
	Nodes []Node
	Kids  []int32 // child lists of KTuple and KList nodes
	Decls []Decl
}

// Children returns the element indices of a KTuple or KList node.
func (p *Program) Children(n *Node) []int32 { return p.Kids[n.A : n.A+n.B] }
